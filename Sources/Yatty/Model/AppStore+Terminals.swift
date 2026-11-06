import AppKit
import GhosttyKit

/// One terminal pane of one worktree.
struct PaneKey: Hashable, Sendable {
  let worktree: String
  let pane: String
}

/// What a terminal asks of the app, mostly from Ghostty's keybinds.
enum TerminalCommand: Sendable {
  case newTab
  case split(SplitAxis, newFirst: Bool)
  case close
  case closeTab
  case gotoSplit(GotoSplit)
  case gotoTab(GotoTab)
  case equalize
  case title(String)
  /// The pane's command exited.
  case childExited
  /// A key pressed on a terminal whose command had exited.
  case closeAfterExit
}

enum GotoSplit: Sendable {
  case previous, next
  case toward(FocusDirection)
}

/// How a pane opened on request starts; used once, when its session is new.
struct PaneLaunch: Sendable {
  /// Runs instead of a shell (a diff viewer): the pane closes when it exits.
  var command: String?
  /// Typed into its new shell (`yatty tab new -- COMMAND`).
  var input: String?
  /// Where its shell starts.
  var cwd: String?
}

extension AppStore {
  func layout(for worktree: Worktree) -> WorktreeLayout {
    layouts[worktree.id] ?? .initial
  }

  /// Applies `change` to the worktree's layout and, unless told not to, saves it.
  func updateLayout(_ worktreeID: String, save: Bool = true, _ change: (inout WorktreeLayout) -> Void) {
    var layout = layouts[worktreeID] ?? .initial
    change(&layout)
    guard layouts[worktreeID] != layout else { return }
    layouts[worktreeID] = layout
    updateVisibility()
    if save { saveState() }
  }

  /// Only the selected worktree's selected tab draws; the rest keep running.
  func updateVisibility() {
    for (key, terminal) in terminals {
      let shown = key.worktree == selection
        && layouts[key.worktree, default: .initial].selected?.root.panes.contains(key.pane) == true
      terminal.setVisible(shown)
    }
  }

  // MARK: Starting terminals

  /// The pane's terminal, or nil while it starts (or can't). Asking for it
  /// the first time starts it.
  func terminal(for key: PaneKey, in worktree: Worktree) -> TerminalView? {
    _ = terminalsStarted
    if let existing = terminals[key] { return existing }
    guard worktree.exists, !failedPanes.contains(key), !disconnectedPanes.contains(key),
      !retiring.contains(key.worktree), !starting.contains(key)
    else { return nil }
    starting.insert(key)
    Task { await startTerminal(key, in: worktree) }
    return nil
  }

  /// What a new terminal types into its shell: the agent command, but only
  /// into a worktree's first pane (or a "New Agent" tab) when its session is
  /// new. A reattached session is never typed into.
  nonisolated static func agentInput(_ command: String, pane: String, sessionIsNew: Bool, agentTab: Bool) -> String? {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, sessionIsNew, pane == "0" || agentTab else { return nil }
    return trimmed + "\n"
  }

  private func startTerminal(_ key: PaneKey, in worktree: Worktree) async {
    defer { starting.remove(key) }
    if worktree.isRemote { return startRemoteTerminal(key, in: worktree) }
    let session = Zmx.sessionName(for: worktree.path, pane: key.pane)
    // A snapshot never starts sessions: its terminals just hold the space.
    guard let live = Snapshot.isActive ? [] : await Zmx.sessions() else {
      failedPanes.insert(key)
      return
    }
    let sandboxed = layouts[key.worktree, default: .initial].sandboxed.contains(key.pane)
    let paneLaunch = paneLaunches[key]
    // The login shell's PATH: Finder's is too thin to find a viewer or the sandbox.
    let loginPath = paneLaunch?.command != nil || sandboxed ? await Task.detached { Run.loginPath }.value : nil
    guard terminals[key] == nil, !retiring.contains(key.worktree),
      layouts[key.worktree, default: .initial].allPanes.contains(key.pane)
    else { return }
    paneLaunches[key] = nil
    guard let app = GhosttyApp.shared.app else {
      Snapshot.note("libghostty app unavailable")
      failedPanes.insert(key)
      return
    }

    // A sandboxed pane only ever starts in the sandbox, after a restart too.
    var program = paneLaunch?.command.map { ["/bin/sh", "-c", $0] } ?? [Zmx.loginShell, "-l"]
    var directory = worktree.path
    if sandboxed {
      guard let prefix = CLIRules.sandboxPrefix(config.sandboxCommand) else {
        Snapshot.note("a sandboxed pane, but no sandboxCommand")
        failedPanes.insert(key)
        return
      }
      program = CLIRules.sandboxArgv(prefix: prefix, program: program, cwd: paneLaunch?.cwd)
    } else if let cwd = paneLaunch?.cwd {
      directory = cwd
    }

    var environment = Zmx.environment
    environment["YATTY_WORKTREE"] = worktree.path
    // Where this pane's agent reports its state (see AgentHooks).
    environment["YATTY_AGENT_DIR"] = AgentHooks.directory.path
    environment["YATTY_PANE"] = session
    environment.merge(CLIServer.paneEnvironment(path: loginPath)) { _, new in new }
    let sessionIsNew = !live.contains(session)
    let agent = AppStore.agentInput(
      AgentHooks.withStatusHooks(config.agentCommand, settingsPath: AgentHooks.settingsURL.path),
      pane: key.pane, sessionIsNew: sessionIsNew, agentTab: agentPanes.remove(key) != nil)
    let typed = paneLaunch?.input.flatMap { sessionIsNew ? $0 + "\n" : nil }
    let launch = TerminalLaunch(
      command: Snapshot.isActive ? "/bin/cat" : Zmx.attachCommand(session: session, command: program),
      workingDirectory: directory,
      environment: environment,
      initialInput: Snapshot.isActive || paneLaunch?.command != nil ? nil : typed ?? agent)
    install(launch, for: key, app: app)
  }

  /// A remote directory's pane: ssh to its host, zmx there. A plain shell;
  /// a "New Agent" tab gets plain `claude` (the status hooks are files on
  /// this Mac).
  private func startRemoteTerminal(_ key: PaneKey, in worktree: Worktree) {
    guard terminals[key] == nil, !retiring.contains(key.worktree),
      layouts[key.worktree, default: .initial].allPanes.contains(key.pane)
    else { return }
    paneLaunches[key] = nil
    let agent = agentPanes.remove(key) != nil
    guard let host = host(of: worktree), let app = GhosttyApp.shared.app else {
      failedPanes.insert(key)
      return
    }
    let session = Zmx.sessionName(for: worktree.sessionKey, pane: key.pane)
    let command = SSH.attachCommand(
      host: host, directory: worktree.path, session: session, program: agent ? SSH.agentProgram : [])
    let launch = TerminalLaunch(
      command: Snapshot.isActive ? "/bin/cat" : command,
      workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
      environment: [:],
      initialInput: nil)
    install(launch, for: key, app: app)
  }

  private func install(_ launch: TerminalLaunch, for key: PaneKey, app: ghostty_app_t) {
    guard let terminal = TerminalView(app: app, launch: launch) else {
      Snapshot.note("libghostty didn't create a surface")
      failedPanes.insert(key)
      return
    }
    terminal.onCommand = { [weak self] command in self?.handle(command, from: key) }
    terminal.onFocus = { [weak self] in self?.paneFocused(key) }
    terminals[key] = terminal
    updateVisibility()
    if focusWhenStarted == key {
      focusWhenStarted = nil
      terminal.focus()
    }
    terminalsStarted += 1
  }

  /// Starts every pane of every tab of the worktree that isn't running yet.
  func startTerminals(of worktree: Worktree) {
    // A remote one starts its panes as they're shown: a password host would
    // otherwise ask once per hidden pane, each a login that could fail.
    guard !Snapshot.isActive, !worktree.isRemote else { return }
    for pane in layout(for: worktree).allPanes {
      _ = terminal(for: PaneKey(worktree: worktree.id, pane: pane), in: worktree)
    }
  }

  func retryPane(_ key: PaneKey) {
    failedPanes.remove(key)
  }

  // MARK: Focus

  /// Gives the pane the keyboard, now or once its terminal has started.
  func focusPane(_ key: PaneKey) {
    updateLayout(key.worktree) { $0.setFocus(key.pane) }
    guard let worktree = worktree(withID: key.worktree) else { return }
    if let terminal = terminal(for: key, in: worktree) {
      terminal.focus()
    } else {
      focusWhenStarted = key
    }
  }

  /// The selected worktree's selected tab's focused pane gets the keyboard.
  func focusSelectedTerminal() {
    guard let worktree = selectedWorktree, let tab = layout(for: worktree).selected else { return }
    focusPane(PaneKey(worktree: worktree.id, pane: tab.focusedPane))
  }

  /// A click (or anything else) put the keyboard in this pane.
  private func paneFocused(_ key: PaneKey) {
    updateLayout(key.worktree) { $0.setFocus(key.pane) }
  }

  // MARK: Tabs and splits

  /// A menu command: acts on the selected worktree's focused pane.
  func performOnFocusedPane(_ command: TerminalCommand) {
    guard let worktree = selectedWorktree else { return }
    guard let tab = layout(for: worktree).selected else {
      if case .newTab = command { newTab(in: worktree, agent: false) }
      return
    }
    handle(command, from: PaneKey(worktree: worktree.id, pane: tab.focusedPane))
  }

  func handle(_ command: TerminalCommand, from key: PaneKey) {
    guard let worktree = worktree(withID: key.worktree) else { return }
    let layout = layout(for: worktree)
    switch command {
    case .newTab:
      newTab(in: worktree, agent: false)
    case .split(let axis, let newFirst):
      split(key, axis: axis, newFirst: newFirst)
    case .close:
      closePane(key)
    case .closeTab:
      if let tab = layout.tab(containing: key.pane) { closeTab(tab.id, in: worktree) }
    case .gotoSplit(let goto):
      guard let tab = layout.tab(containing: key.pane) else { return }
      let panes = tab.root.panes
      let index = panes.firstIndex(of: key.pane) ?? 0
      let target: String? =
        switch goto {
        case .previous: panes[(index - 1 + panes.count) % panes.count]
        case .next: panes[(index + 1) % panes.count]
        case .toward(let direction): tab.root.neighbor(of: key.pane, toward: direction)
        }
      if let target, target != key.pane { focusPane(PaneKey(worktree: key.worktree, pane: target)) }
    case .gotoTab(let goto):
      if let tabID = layout.tabID(for: goto) { selectTab(tabID, in: worktree) }
    case .equalize:
      if let tab = layout.tab(containing: key.pane) { equalize(tab.id, in: worktree) }
    case .title(let title):
      if paneTitles[key] != title { paneTitles[key] = title }
    case .closeAfterExit:
      // On a dropped connection: go back, rather than end the session.
      if disconnectedPanes.contains(key) { reconnect(key) } else { closePane(key) }
    case .childExited:
      if worktree.isRemote {
        remotePaneExited(key, in: worktree)
      } else {
        closePane(key)
      }
    }
  }

  /// A new tab after the selected one, with a shell (or the agent command).
  func newTab(in worktree: Worktree, agent: Bool) {
    let key = PaneKey(worktree: worktree.id, pane: newPaneID())
    if agent { agentPanes.insert(key) }
    updateLayout(worktree.id) { $0.addTab(pane: key.pane, id: "t" + newPaneID()) }
    focusPane(key)
  }

  /// A tab running `command` (a diff viewer) instead of a shell, named
  /// `name`; it closes when the command exits.
  func newTab(in worktree: Worktree, command: String, name: String, sandboxed: Bool = false) {
    let key = PaneKey(worktree: worktree.id, pane: newPaneID())
    paneLaunches[key] = PaneLaunch(command: command)
    let tabID = "t" + newPaneID()
    updateLayout(worktree.id) {
      $0.addTab(pane: key.pane, id: tabID)
      $0.rename(tabID, to: name)
      if sandboxed { $0.sandboxed.insert(key.pane) }
    }
    focusPane(key)
  }

  func split(_ key: PaneKey, axis: SplitAxis, newFirst: Bool) {
    let new = PaneKey(worktree: key.worktree, pane: newPaneID())
    updateLayout(key.worktree) { $0.split(key.pane, new: new.pane, axis: axis, newFirst: newFirst) }
    focusPane(new)
  }

  /// Ends the pane's session. Its sibling takes the space and the keyboard.
  func closePane(_ key: PaneKey) {
    guard layouts[key.worktree, default: .initial].allPanes.contains(key.pane),
      let worktree = worktree(withID: key.worktree)
    else { return }
    let hadKeyboard = terminals[key].map { $0.window?.firstResponder === $0 } ?? false
    dropTerminal(key)
    updateLayout(key.worktree) { $0.close(key.pane) }
    Task { await endSessions([key.pane], of: worktree) }
    if hadKeyboard { focusSelectedTerminal() }
  }

  func closeTab(_ tabID: String, in worktree: Worktree) {
    guard let tab = layout(for: worktree).tabs.first(where: { $0.id == tabID }) else { return }
    for pane in tab.root.panes {
      dropTerminal(PaneKey(worktree: worktree.id, pane: pane))
      updateLayout(worktree.id) { $0.close(pane) }
    }
    Task { await endSessions(tab.root.panes, of: worktree) }
    if selection == worktree.id { focusSelectedTerminal() }
  }

  func selectTab(_ tabID: String, in worktree: Worktree) {
    updateLayout(worktree.id) { $0.select(tabID) }
    if selection == worktree.id { focusSelectedTerminal() }
  }

  func renameTab(_ tabID: String, to name: String, in worktree: Worktree) {
    updateLayout(worktree.id) { $0.rename(tabID, to: name) }
  }

  /// A drag sets the ratio on every move with `save: false`, then saves once.
  func setRatio(_ ratio: Double, at path: [Bool], tab tabID: String, in worktree: Worktree, save: Bool = true) {
    updateLayout(worktree.id, save: save) { $0.setRatio(ratio, at: path, in: tabID) }
  }

  func equalize(_ tabID: String, in worktree: Worktree) {
    updateLayout(worktree.id) { $0.equalize(tabID) }
  }

  /// The tab's title: the name the user gave it, else its focused terminal's.
  func title(of tab: TerminalTab, in worktree: Worktree) -> String {
    tab.name ?? paneTitles[PaneKey(worktree: worktree.id, pane: tab.focusedPane)] ?? "Terminal"
  }

  // MARK: Teardown

  private func dropTerminal(_ key: PaneKey) {
    terminals.removeValue(forKey: key)?.destroy()
    failedPanes.remove(key)
    disconnectedPanes.remove(key)
    paneTitles[key] = nil
    agentPanes.remove(key)
    paneLaunches[key] = nil
  }

  /// Destroys every terminal of the worktree, forgets its layout and ends
  /// its sessions. Nothing for it can start meanwhile.
  func endTerminals(of worktree: Worktree) async {
    retiring.insert(worktree.id)
    defer { retiring.remove(worktree.id) }
    let panes = Set(layout(for: worktree).allPanes).union(["0"])
    for pane in panes { dropTerminal(PaneKey(worktree: worktree.id, pane: pane)) }
    layouts[worktree.id] = nil
    labels[worktree.id] = nil
    saveState()
    await endSessions(Array(panes), of: worktree)
  }

  /// Ends the panes' zmx sessions: here, or on the worktree's host.
  func endSessions(_ panes: [String], of worktree: Worktree) async {
    let names = panes.map { Zmx.sessionName(for: worktree.sessionKey, pane: $0) }
    if worktree.isRemote {
      // Unreachable now: they're ended once it can be reached.
      if let host = host(of: worktree), !(await SSH.kill(names, on: host)) { remember(names, toEndOn: host) }
    } else {
      for name in names { await Zmx.kill(name) }
    }
  }

  /// A remote pane's ssh ended: the shell there exited, or the connection
  /// went. (libghostty starts commands through login(1), which always exits
  /// 0, so ssh's own status never arrives.) The host says which: a session
  /// that's gone closes the pane; one still there, or a host that can't be
  /// asked, leaves it waiting to reconnect.
  private func remotePaneExited(_ key: PaneKey, in worktree: Worktree) {
    // The terminal stays, showing what ssh said, under a Reconnect bar.
    disconnectedPanes.insert(key)
    guard let host = host(of: worktree) else { return }
    let session = Zmx.sessionName(for: worktree.sessionKey, pane: key.pane)
    Task {
      if await SSH.sessionExists(session, on: host) == false, disconnectedPanes.contains(key) {
        closePane(key)
      }
    }
  }

  func reconnect(_ key: PaneKey) {
    dropTerminal(key)
    focusPane(key)
  }
}
