import Foundation

/// The code beside a tab's terminals: showing it, what it follows, and the
/// comments it hands to the agent.
extension AppStore {
  func codePage(for tabID: String) -> CodePage {
    if let page = codePages[tabID] { return page }
    let page = CodePage()
    codePages[tabID] = page
    return page
  }

  /// Shows or hides the code beside the selected tab's terminals.
  func toggleCode(in worktree: Worktree) {
    guard !worktree.isRemote, let tab = layout(for: worktree).selected, tab.diff == nil else { return }
    let shown = !(tab.code?.shown ?? false)
    updateLayout(worktree.id) { $0.updateCode(tab.id) { $0.shown = shown } }
    if shown {
      watchCode(in: worktree)
    } else {
      stopWatchingCodeIfUnused(in: worktree)
      if codeQuickOpen == tab.id { codeQuickOpen = nil }
      // The code may have had the keyboard; it goes back to the terminal.
      focusPane(PaneKey(worktree: worktree.id, pane: tab.focusedPane))
    }
  }

  /// Opens `file` in the tab's code view; the user chose it, so the view
  /// stops following the agent.
  func openCode(_ file: String, tab tabID: String, in worktree: Worktree, following: Bool = false) {
    updateLayout(worktree.id) {
      $0.updateCode(tabID) {
        $0.file = file
        $0.following = following
      }
    }
  }

  func setCodeFollowing(_ following: Bool, tab tabID: String, in worktree: Worktree) {
    guard layout(for: worktree).tabs.first(where: { $0.id == tabID })?.code?.following != following else { return }
    updateLayout(worktree.id) { $0.updateCode(tabID) { $0.following = following } }
  }

  func setCodeBase(_ base: CodeView.Base, tab tabID: String, in worktree: Worktree) {
    updateLayout(worktree.id) { $0.updateCode(tabID) { $0.base = base } }
  }

  func setCodeRatio(_ ratio: Double, tab tabID: String, in worktree: Worktree, save: Bool) {
    updateLayout(worktree.id, save: save) { $0.updateCode(tabID) { $0.ratio = min(max(ratio, 0.2), 0.85) } }
  }

  func saveCodeComment(_ comment: DiffComment, tab tabID: String, in worktree: Worktree) {
    updateLayout(worktree.id) { layout in
      layout.updateCode(tabID) { code in
        if let index = code.comments.firstIndex(where: { $0.id == comment.id }) {
          code.comments[index] = comment
        } else {
          code.comments.append(comment)
        }
      }
    }
  }

  func deleteCodeComment(_ id: String, tab tabID: String, in worktree: Worktree) {
    updateLayout(worktree.id) { $0.updateCode(tabID) { $0.comments.removeAll { $0.id == id } } }
  }

  func clearCodeComments(tab tabID: String, in worktree: Worktree) {
    updateLayout(worktree.id) { $0.updateCode(tabID) { $0.comments = [] } }
  }

  /// Where the page found the comments' lines; saved only when that changed something.
  func placeCodeComments(_ anchors: [DiffComment.Anchor], tab tabID: String, in worktree: Worktree) {
    guard let code = layout(for: worktree).tabs.first(where: { $0.id == tabID })?.code else { return }
    var tab = DiffTab(target: .working, comments: code.comments)
    guard tab.place(anchors) else { return }
    updateLayout(worktree.id) { $0.updateCode(tabID) { $0.comments = tab.comments } }
  }

  /// The prompt for the comments: those not sent yet, or all of them.
  func codePrompt(tab tabID: String, in worktree: Worktree, unsentOnly: Bool) async -> String? {
    guard let code = layout(for: worktree).tabs.first(where: { $0.id == tabID })?.code else { return nil }
    let comments = unsentOnly ? code.comments.filter { !$0.sent } : code.comments
    guard !comments.isEmpty else { return nil }
    var target = DiffTarget.working
    if code.base == .branch, let repo = repo(of: worktree) {
      let base = await Git.defaultBase(root: repo.path)
      if base != "HEAD" { target = .base(base) }
    }
    return LocalReviewPrompt.make(target: target, branch: worktree.branch, comments: comments, view: "code view")
  }

  /// The terminal in the tab an agent reports from; nil when none does, or
  /// while it's asking the user something.
  func agentPane(of tab: TerminalTab, in worktree: Worktree) -> String? {
    let state = { (pane: String) in self.agents.panes[PaneKey(worktree: worktree.id, pane: pane)] }
    let reporting = Set(tab.root.panes.filter { state($0) != nil })
    let asking = Set(tab.root.panes.filter { state($0) == .needsAction })
    return CodeAgent.pane(in: tab.root.panes, focused: tab.focusedPane, reporting: reporting, asking: asking)
  }

  /// An agent in the tab is waiting on the user (a permission, a question, a plan).
  func agentAsking(in tab: TerminalTab, of worktree: Worktree) -> Bool {
    tab.root.panes.contains { agents.panes[PaneKey(worktree: worktree.id, pane: $0)] == .needsAction }
  }

  /// Pastes the comments not sent yet into the tab's agent and submits them;
  /// false when there was nothing to send, no agent reports from the tab,
  /// or its terminal isn't running.
  func sendCodeComments(tab tabID: String, in worktree: Worktree) async -> Bool {
    guard let tab = layout(for: worktree).tabs.first(where: { $0.id == tabID }), let code = tab.code,
      let prompt = await codePrompt(tab: tabID, in: worktree, unsentOnly: true)
    else { return false }
    let sending = Set(code.comments.filter { !$0.sent }.map(\.id))
    // Never a shell: Enter would run what it was pasted, quoted code and all.
    guard let pane = agentPane(of: tab, in: worktree) else { return false }
    let session = Zmx.sessionName(for: worktree.sessionKey, pane: pane)
    let input = AgentInput.paste(prompt)
    guard await Zmx.send(session, input.text) else { return false }
    // A moment for the paste to land before Enter.
    try? await Task.sleep(for: .milliseconds(150))
    _ = await Zmx.send(session, input.submit)
    updateLayout(worktree.id) {
      $0.updateCode(tabID) { code in
        for index in code.comments.indices where sending.contains(code.comments[index].id) { code.comments[index].sent = true }
      }
    }
    focusPane(PaneKey(worktree: worktree.id, pane: pane))
    return true
  }

  // MARK: Following changes

  /// Starts telling the worktree's code views which files change.
  func watchCode(in worktree: Worktree) {
    guard !worktree.isRemote, codeWatchers[worktree.id] == nil else { return }
    let id = worktree.id
    let watcher = CodeWatcher(root: worktree.path) { [weak self] paths in
      Task { @MainActor in await self?.filesChanged(paths, in: id) }
    }
    codeWatchers[worktree.id] = watcher
  }

  /// Stops once no tab of the worktree shows code.
  func stopWatchingCodeIfUnused(in worktree: Worktree) {
    guard !layout(for: worktree).tabs.contains(where: { $0.code?.shown == true }) else { return }
    codeWatchers.removeValue(forKey: worktree.id)?.stop()
  }

  /// Files changed under the worktree: the last one that's a file git doesn't
  /// ignore becomes the one its code views follow.
  private func filesChanged(_ absolute: [String], in worktreeID: String) async {
    guard let watcher = codeWatchers[worktreeID],
      let worktree = worktrees.values.flatMap({ $0 }).first(where: { $0.id == worktreeID })
    else { return }
    // Worktrees inside this one (a main checkout's .worktrees/) change on their own.
    let nested = worktrees.values.flatMap { $0 }.filter { $0.path.hasPrefix(worktree.path + "/") }
      .map { String($0.path.dropFirst(worktree.path.count + 1)) }
    let changed = Array(CodeWatch.relative(absolute, in: watcher.root, excluding: nested).suffix(200))
    guard !changed.isEmpty else { return }
    let files = await CodeSource.followable(changed, in: worktree.path)
    guard let last = files.last else { return }
    let serial = (codeChanges[worktreeID]?.serial ?? 0) + 1
    codeChanges[worktreeID] = CodeChangeEvent(path: last, paths: files, serial: serial)
  }

  /// Lets go of a closed tab's code page.
  func forgetCode(_ tabID: String) {
    codePages.removeValue(forKey: tabID)?.close()
    codeSeen[tabID] = nil
    if codeQuickOpen == tabID { codeQuickOpen = nil }
  }
}
