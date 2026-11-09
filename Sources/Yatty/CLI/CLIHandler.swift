import Foundation
import YattyProtocol

/// What the `yatty` CLI's requests do: they act on the requesting worktree's
/// tabs as the tab bar would.
extension AppStore {
  func startCLIServers() {
    guard !Snapshot.isActive else { return }
    let handler: CLIServer.Handler = { [weak self] request, sandboxed in
      guard let self else { return .failure("Yatty is quitting") }
      return await self.answer(request, sandboxed: sandboxed)
    }
    cliServers = [
      CLIServer(path: CLIPaths.appSocket(), sandboxed: false, handler: handler),
      CLIServer(path: CLIPaths.sandboxSocket(), sandboxed: true, handler: handler),
    ].compactMap { $0 }
  }

  func answer(_ request: CLIRequest, sandboxed: Bool) async -> CLIResponse {
    do {
      return CLIResponse(ok: true, output: try await perform(request, sandboxed: sandboxed))
    } catch let error as CLIError {
      return .failure(error.message)
    } catch {
      return .failure(error.localizedDescription)
    }
  }

  private func perform(_ request: CLIRequest, sandboxed: Bool) async throws -> String {
    if request.op == .status { return status(request) }
    let worktree = try cliWorktree(request.worktree)
    // `tab send` types into the tab's focused pane.
    let typedInto = request.op == .tabSend ? try cliTab(request.tab, in: worktree).tab.focusedPane : nil
    if let refusal = CLIRules.refusal(
      request, sandboxed: sandboxed, sandboxCommand: config.sandboxCommand,
      targetSandboxed: typedInto.map { layout(for: worktree).sandboxed.contains($0) } ?? false)
    {
      throw CLIError(refusal)
    }
    switch request.op {
    case .status: return status(request)
    case .tabList: return tabList(request, in: worktree)
    case .tabNew: return try tabNew(request, in: worktree, sandboxed: sandboxed)
    case .tabRead:
      // The CLI checks it too, but anything can write to the socket.
      if let lines = request.lines, lines < 1 { throw CLIError("--lines needs a positive number") }
      let (tab, number) = try cliTab(request.tab, in: worktree)
      guard tab.diff == nil else { throw CLIError("tab \(number) shows a diff, not a terminal") }
      guard let history = await Zmx.history(Zmx.sessionName(for: worktree.path, pane: tab.focusedPane)) else {
        throw CLIError("tab \(number)'s terminal isn't running")
      }
      return CLIRules.lastLines(history, count: request.lines ?? 50)
    case .tabSend:
      let (tab, number) = try cliTab(request.tab, in: worktree)
      guard tab.diff == nil else { throw CLIError("tab \(number) shows a diff, not a terminal") }
      let input = try CLIRules.input(request).get()
      guard !input.isEmpty, let pane = typedInto else { throw CLIError("nothing to send: give TEXT or --key") }
      // The pane that was checked, whatever the tab's focus is by now.
      guard await Zmx.send(Zmx.sessionName(for: worktree.path, pane: pane), input) else {
        throw CLIError("tab \(number)'s terminal isn't running")
      }
      return ""
    case .tabSelect:
      let (tab, _) = try cliTab(request.tab, in: worktree)
      selectTab(tab.id, in: worktree)
      return ""
    case .tabRename:
      let (tab, _) = try cliTab(request.tab, in: worktree)
      guard let name = request.name?.trimmingCharacters(in: .whitespacesAndNewlines) else {
        throw CLIError("rename to what? give a NAME")
      }
      if let bad = CLIRules.badName(name) { throw CLIError(bad) }
      var others = tabTitles(in: worktree)
      if let index = layout(for: worktree).tabs.firstIndex(where: { $0.id == tab.id }) { others[index] = "" }
      if let clash = CLIRules.nameClash(name, titles: others) { throw CLIError(clash) }
      renameTab(tab.id, to: name, in: worktree)
      return ""
    case .tabClose:
      let (tab, _) = try cliTab(request.tab, in: worktree)
      // Closing the last terminal would leave the worktree with none at all.
      guard layout(for: worktree).canClose(tab.id) else { throw CLIError("that's the only terminal tab; it stays") }
      closeTab(tab.id, in: worktree)
      return ""
    case .diff: return try await diff(request, in: worktree, sandboxed: sandboxed)
    case .notify: return try await notify(request, in: worktree)
    }
  }

  // MARK: Lookups

  /// The known worktree at `path` (or holding it).
  private func cliWorktree(_ path: String?) throws -> Worktree {
    guard let path, !path.isEmpty else { throw CLIError("not in a Yatty terminal: pass --worktree PATH") }
    let canonical = canonicalPath(path)
    let all = worktrees.values.flatMap { $0 }
    let match = all.first { $0.path == canonical }
      ?? all.filter { canonical.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
    guard let match else { throw CLIError("no worktree in Yatty at \(path)") }
    return match
  }

  private func tabTitles(in worktree: Worktree) -> [String] {
    layout(for: worktree).tabs.map { title(of: $0, in: worktree) }
  }

  /// The tab `ref` names, and its number.
  private func cliTab(_ ref: String?, in worktree: Worktree) throws -> (tab: TerminalTab, number: Int) {
    guard let ref else { throw CLIError("which tab? give its number or name") }
    let titles = tabTitles(in: worktree)
    guard let index = CLIRules.tabIndex(ref, titles: titles) else { throw CLIError(CLIRules.noTab(ref, titles: titles)) }
    return (layout(for: worktree).tabs[index], index + 1)
  }

  // MARK: Operations

  private struct TabRow: Encodable {
    let index: Int
    let name: String
    let active: Bool
    let panes: Int
    let sandboxed: Bool
  }

  private func tabList(_ request: CLIRequest, in worktree: Worktree) -> String {
    let layout = layout(for: worktree)
    let rows = layout.tabs.enumerated().map { offset, tab in
      TabRow(
        index: offset + 1, name: title(of: tab, in: worktree), active: tab.id == layout.selectedTab,
        panes: tab.root.panes.count, sandboxed: layout.sandboxed.contains(tab.focusedPane))
    }
    if request.json { return json(rows) }
    return rows.map { row in
      "\(row.index)\t\(row.name)" + (row.active ? "\t(active)" : "") + (row.panes > 1 ? "\t\(row.panes) panes" : "")
    }.joined(separator: "\n")
  }

  /// No suspension between the name check and the new tab: two requests in
  /// one burst can't both find a name free.
  private func tabNew(_ request: CLIRequest, in worktree: Worktree, sandboxed: Bool) throws -> String {
    let name = request.name?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let name, let bad = CLIRules.badName(name) { throw CLIError(bad) }
    if let clash = CLIRules.nameClash(name, titles: tabTitles(in: worktree)) { throw CLIError(clash) }
    var cwd = request.cwd
    // A sandboxed one moves there inside the sandbox; asking the app whether
    // it exists would tell the sandbox about paths it can't see.
    if let given = cwd, !sandboxed {
      cwd = given.hasPrefix("/") ? given : (worktree.path as NSString).appendingPathComponent(given)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: cwd!, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw CLIError("--cwd: no directory \(given)")
      }
    }
    let key = PaneKey(worktree: worktree.id, pane: newPaneID())
    let tabID = "t" + newPaneID()
    paneLaunches[key] = PaneLaunch(input: CLIRules.commandLine(request.command), cwd: cwd)
    updateLayout(worktree.id) {
      // At the end, as agentree does: the number it prints stays the tab's.
      $0.addTab(pane: key.pane, id: tabID, select: request.select, atEnd: true)
      if let name { $0.rename(tabID, to: name) }
      if sandboxed { $0.sandboxed.insert(key.pane) }
    }
    if request.select && selection == worktree.id {
      focusPane(key)
    } else {
      // In the background it still starts now, so its command runs.
      _ = terminal(for: key, in: worktree)
    }
    let index = (layout(for: worktree).tabs.firstIndex { $0.id == tabID } ?? 0) + 1
    if request.json {
      struct Created: Encodable { let index: Int; let name: String? }
      return json(Created(index: index, name: name))
    }
    return String(index)
  }

  private func diff(_ request: CLIRequest, in worktree: Worktree, sandboxed: Bool) async throws -> String {
    guard let repo = repo(of: worktree) else { throw CLIError("no repository holds \(worktree.path)") }
    let word = request.target ?? "working"
    let base = word == "base" ? await Git.defaultBase(root: repo.path) : ""
    let target = try CLIRules.diffTarget(word, base: base).get()
    let available = await Task.detached { DiffViewers.available(in: Run.loginPath) }.value
    let chosen = DiffViewers.resolve(diffViewer, available: available)
    // A sandboxed agent's diff runs in a sandboxed tab, never in the app.
    let viewer = sandboxed ? DiffViewers.forSandbox(chosen, available: available) : chosen
    // It may have been closed meanwhile.
    guard let current = self.worktree(withID: worktree.id) else { throw CLIError("the worktree was closed") }
    if viewer == .yatty {
      openDiff(current, target: target)
      return "diff (\(word)) opened in a diff tab"
    }
    newTab(
      in: current, command: DiffViewers.command(viewer, args: target.args), name: "diff: \(target.title)",
      sandboxed: sandboxed)
    return "diff (\(word)) opened in \(viewer.label)"
  }

  private func notify(_ request: CLIRequest, in worktree: Worktree) async throws -> String {
    let message = request.text.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else { throw CLIError("notify what? give a MESSAGE") }
    let layout = layout(for: worktree)
    // Clicking it opens the pane that asked, when it's one of this worktree's.
    let pane = request.pane.flatMap { session in
      layout.allPanes.first { Zmx.sessionName(for: worktree.path, pane: $0) == session }
    } ?? layout.selected?.focusedPane ?? "0"
    let title = request.title ?? label(for: worktree)
    let posted = await agents.post(
      title: title, subtitle: repo(of: worktree)?.name ?? "", body: message,
      about: PaneKey(worktree: worktree.id, pane: pane))
    guard posted else { throw CLIError("Yatty may not show notifications: allow them in System Settings → Notifications") }
    return "sent"
  }

  private struct StatusRow: Encodable {
    let project: String
    let worktree: String
    let branch: String?
    let path: String
    let agent: String
    let here: Bool
  }

  private func status(_ request: CLIRequest) -> String {
    let here = request.worktree.map(canonicalPath)
    let rows = repos.flatMap { repo in
      (worktrees[repo.id] ?? []).map { worktree in
        StatusRow(
          project: repo.name, worktree: label(for: worktree), branch: worktree.branch, path: worktree.path,
          agent: agents.state(of: worktree)?.rawValue ?? "none", here: worktree.path == here)
      }
    }
    if request.json { return json(rows) }
    return rows.map { row in
      (row.here ? "* " : "  ") + "\(row.project)/\(row.worktree)\t\(row.agent)" + (row.branch.map { "\t\($0)" } ?? "")
    }.joined(separator: "\n")
  }

  private func json(_ value: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
  }
}
