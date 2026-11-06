import AppKit
import Observation

struct PendingClose: Identifiable {
  let repo: Repo
  let worktree: Worktree
  var id: String { worktree.id }
}

struct AppAlert: Identifiable {
  let id = UUID()
  let title: String
  let message: String
}

/// Repositories, their worktrees (read from git, never stored), and one
/// terminal per worktree that stays alive while you look at another.
@MainActor
@Observable
final class AppStore {
  var repos: [Repo]
  /// Per repository path, main working copy first.
  var worktrees: [String: [Worktree]] = [:]
  var loadErrors: [String: String] = [:]
  var selection: String? {
    didSet {
      guard selection != oldValue else { return }
      for (id, terminal) in terminals { terminal.setVisible(id == selection) }
      saveState()
    }
  }
  /// Worktrees whose terminal process exited; they wait for "Start New Session".
  var endedSessions: Set<String> = []
  /// Worktrees whose terminal couldn't start; they wait for "Try Again".
  var failedTerminals: Set<String> = []
  /// Bumped when a terminal finishes starting, so views asking for it look again.
  private var terminalsStarted = 0

  var alert: AppAlert?
  var newWorktreeRepo: Repo?
  var pendingClose: PendingClose?
  var pendingRemoval: Repo?

  let config = ConfigFiles.loadConfig()
  @ObservationIgnored private var terminals: [String: TerminalView] = [:]
  @ObservationIgnored private var starting: Set<String> = []
  /// Worktrees being closed or removed: no terminal may start for them.
  @ObservationIgnored private var retiring: Set<String> = []
  @ObservationIgnored private var focusWhenStarted: String?

  /// False when state.json couldn't be read: the repos it listed are unknown,
  /// so their sessions must not be reaped as orphans.
  @ObservationIgnored private let reposKnown: Bool

  init() {
    switch ConfigFiles.loadState() {
    case .missing:
      repos = []
      reposKnown = true
    case .loaded(let stored):
      repos = stored.repos
      selection = stored.selectedWorktree
      reposKnown = true
    case .unreadable(let aside):
      repos = []
      reposKnown = false
      alert = AppAlert(
        title: "Couldn't read Yatty's state",
        message: "It was moved to \(aside.path). Add your repositories again; their terminals are still running.")
    }
    Task { await refreshAll() }
    // Worktrees made outside Yatty (by hand, by an agent) show up on return.
    NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        Task { await self.refreshAll() }
      }
    }
  }

  var selectedWorktree: Worktree? {
    guard let selection else { return nil }
    return worktrees.values.lazy.flatMap { $0 }.first { $0.id == selection }
  }

  func repo(of worktree: Worktree) -> Repo? {
    repos.first { worktrees[$0.id]?.contains(worktree) == true }
  }

  // MARK: Loading

  func refreshAll() async {
    for repo in repos { await refresh(repo) }
    await reapOrphanSessions()
  }

  /// Ends Yatty sessions no known worktree owns: their worktree was deleted,
  /// or their repository removed, while Yatty wasn't looking. Only once every
  /// repository has loaded, so a failed read never costs a live session.
  private func reapOrphanSessions() async {
    guard reposKnown, !repos.isEmpty, loadErrors.isEmpty, repos.allSatisfy({ worktrees[$0.id] != nil }),
      let live = await Zmx.sessions()
    else { return }
    let known = Set(worktrees.values.joined().map { Zmx.sessionName(for: $0.path) })
    for name in live where name.hasPrefix("yatty-") && !known.contains(name) {
      await Zmx.kill(name)
    }
  }

  func refresh(_ repo: Repo) async {
    do {
      let list = try await Git.listWorktrees(root: repo.path)
      let alive = Set(list.map(\.id))
      let gone = (worktrees[repo.id] ?? []).filter { !alive.contains($0.id) }
      worktrees[repo.id] = list
      loadErrors[repo.id] = nil
      // A worktree removed outside Yatty takes its terminal and session with it.
      for worktree in gone {
        dropTerminal(worktree.id)
        await Zmx.kill(Zmx.sessionName(for: worktree.path))
      }
    } catch {
      loadErrors[repo.id] = error.localizedDescription
    }
  }

  // MARK: Terminals

  /// The worktree's terminal, or nil while it starts (or can't). Asking for
  /// it the first time starts it.
  func terminal(for worktree: Worktree) -> TerminalView? {
    _ = terminalsStarted
    if let existing = terminals[worktree.id] { return existing }
    let id = worktree.id
    guard worktree.exists, !endedSessions.contains(id), !failedTerminals.contains(id),
      !retiring.contains(id), !starting.contains(id)
    else { return nil }
    starting.insert(id)
    Task { await startTerminal(for: worktree) }
    return nil
  }

  /// A new zmx session gets the agent command typed into its shell, as
  /// agentree does; an existing one is just reattached.
  private func startTerminal(for worktree: Worktree) async {
    let id = worktree.id
    defer { starting.remove(id) }
    let session = Zmx.sessionName(for: worktree.path)
    guard let live = await Zmx.sessions() else {
      failedTerminals.insert(id)
      return
    }
    guard terminals[id] == nil, !retiring.contains(id) else { return }
    guard let app = GhosttyApp.shared.app else {
      failedTerminals.insert(id)
      return
    }

    var environment = Zmx.environment
    environment["YATTY_WORKTREE"] = worktree.path
    let agent = config.agentCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    let launch = TerminalLaunch(
      command: Zmx.attachCommand(session: session),
      workingDirectory: worktree.path,
      environment: environment,
      initialInput: !live.contains(session) && !agent.isEmpty ? agent + "\n" : nil)
    guard let terminal = TerminalView(app: app, launch: launch) else {
      failedTerminals.insert(id)
      return
    }
    terminal.onClose = { [weak self] in self?.terminalEnded(id) }
    terminal.setVisible(id == selection)
    terminals[id] = terminal
    if focusWhenStarted == id {
      focusWhenStarted = nil
      terminal.focus()
    }
    terminalsStarted += 1
  }

  func focusSelectedTerminal() {
    guard let worktree = selectedWorktree else { return }
    if let terminal = terminal(for: worktree) {
      terminal.focus()
    } else {
      focusWhenStarted = worktree.id
    }
  }

  func restartSession(_ id: String) {
    endedSessions.remove(id)
  }

  func retryTerminal(_ id: String) {
    failedTerminals.remove(id)
  }

  /// Destroys the worktree's terminal, if any, and forgets its state.
  private func dropTerminal(_ id: String) {
    terminals.removeValue(forKey: id)?.destroy()
    endedSessions.remove(id)
    failedTerminals.remove(id)
  }

  private func terminalEnded(_ id: String) {
    terminals.removeValue(forKey: id)?.destroy()
    endedSessions.insert(id)
  }

  // MARK: Repositories

  func chooseRepository() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Add"
    panel.message = "Choose a git repository"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { await addRepository(at: url.path) }
  }

  func addRepository(at path: String) async {
    do {
      let root = canonicalPath(try await Git.mainRoot(containing: path))
      if !repos.contains(where: { $0.id == root }) {
        repos.append(Repo(path: root, name: URL(fileURLWithPath: root).lastPathComponent))
        saveState()
      }
      if let repo = repos.first(where: { $0.id == root }) {
        await refresh(repo)
        selection = worktrees[repo.id]?.first?.id
      }
    } catch {
      alert = AppAlert(title: "Not a git repository", message: error.localizedDescription)
    }
  }

  /// Forgets the repository and ends its terminals' sessions; files stay.
  func removeRepository(_ repo: Repo) async {
    let list = worktrees[repo.id] ?? []
    // Out of view and unstartable before anything awaits.
    for worktree in list {
      retiring.insert(worktree.id)
      dropTerminal(worktree.id)
    }
    defer { list.forEach { retiring.remove($0.id) } }
    if list.contains(where: { $0.id == selection }) { selection = nil }
    repos.removeAll { $0.id == repo.id }
    worktrees[repo.id] = nil
    loadErrors[repo.id] = nil
    saveState()
    // A repository that never loaded has no list; the next refresh reaps its sessions.
    for worktree in list { await Zmx.kill(Zmx.sessionName(for: worktree.path)) }
  }

  // MARK: Worktrees

  func newWorktreeForSelection() {
    newWorktreeRepo = selectedWorktree.flatMap(repo(of:)) ?? repos.first
  }

  func requestCloseSelected() {
    guard let worktree = selectedWorktree, !worktree.isMain, let repo = repo(of: worktree) else { return }
    pendingClose = PendingClose(repo: repo, worktree: worktree)
  }

  /// A new branch from `base` in `<repo>/.worktrees/<branch>`, opened with
  /// its agent and the keyboard in its terminal.
  func createWorktree(in repo: Repo, branch: String, base: String) async throws {
    await Git.ignoreWorktreesDir(root: repo.path)
    let path = URL(fileURLWithPath: repo.path)
      .appendingPathComponent(".worktrees")
      .appendingPathComponent(Git.directoryName(for: branch)).path
    try await Git.addWorktree(root: repo.path, path: path, branch: branch, base: base)
    await refresh(repo)
    selection = canonicalPath(path)
    focusSelectedTerminal()
  }

  /// Deletes the worktree's directory (uncommitted changes too) and ends its
  /// session. The branch stays.
  func closeWorktree(_ pending: PendingClose) async {
    let worktree = pending.worktree
    // Out of view and unstartable before anything awaits.
    retiring.insert(worktree.id)
    defer { retiring.remove(worktree.id) }
    if selection == worktree.id { selection = worktrees[pending.repo.id]?.first?.id }
    dropTerminal(worktree.id)
    await Zmx.kill(Zmx.sessionName(for: worktree.path))
    do {
      try await Git.removeWorktree(root: pending.repo.path, path: worktree.path)
    } catch {
      alert = AppAlert(title: "Couldn't close \(worktree.name)", message: error.localizedDescription)
    }
    await refresh(pending.repo)
  }

  private func saveState() {
    ConfigFiles.saveState(StoredState(repos: repos, selectedWorktree: selection))
  }
}
