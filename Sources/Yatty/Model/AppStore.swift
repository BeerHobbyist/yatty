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

/// Repositories, their worktrees (read from git, never stored), and each
/// worktree's tabs and splits, whose terminals stay alive while hidden.
/// Terminal operations are in AppStore+Terminals.swift.
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
      updateVisibility()
      saveState()
    }
  }
  /// Per worktree path; see `layout(for:)`.
  var layouts: [String: WorktreeLayout] = [:]
  /// Panes whose terminal couldn't start; they wait for "Try Again".
  var failedPanes: Set<PaneKey> = []
  /// What each pane's terminal calls itself (OSC 0/2).
  var paneTitles: [PaneKey: String] = [:]
  /// Bumped when a terminal finishes starting, so views asking for it look again.
  var terminalsStarted = 0

  var alert: AppAlert?
  var addingRepository = false
  var newWorktreeRepo: Repo?
  var pendingClose: PendingClose?
  var pendingRemoval: Repo?

  let config = ConfigFiles.loadConfig()
  let catalog = RepoCatalog()
  @ObservationIgnored var terminals: [PaneKey: TerminalView] = [:]
  @ObservationIgnored var starting: Set<PaneKey> = []
  /// Panes opened with "New Agent": their new session gets the agent command.
  @ObservationIgnored var agentPanes: Set<PaneKey> = []
  /// Worktrees being closed or removed: no terminal may start for them.
  @ObservationIgnored var retiring: Set<String> = []
  @ObservationIgnored var focusWhenStarted: PaneKey?

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
      layouts = stored.layouts
      reposKnown = true
    case .unreadable(let aside):
      repos = []
      reposKnown = false
      alert = AppAlert(
        title: "Couldn't read Yatty's state",
        message: "It was moved to \(aside.path). Add your repositories again; their terminals are still running.")
    }
    Task { await refreshAll() }
    if Snapshot.sheet == "add-repository" { addingRepository = true }
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
    return worktree(withID: selection)
  }

  func worktree(withID id: String) -> Worktree? {
    worktrees.values.lazy.flatMap { $0 }.first { $0.id == id }
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
    guard !Snapshot.isActive, reposKnown, !repos.isEmpty, loadErrors.isEmpty,
      repos.allSatisfy({ worktrees[$0.id] != nil }),
      let live = await Zmx.sessions()
    else { return }
    let known = Zmx.knownSessions(worktrees: Array(worktrees.values.joined()), layouts: layouts)
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
      // Repositories added before Yatty knew their GitHub name learn it here.
      if repo.nameWithOwner == nil, let slug = await Git.remoteSlug(root: repo.path),
        let index = repos.firstIndex(where: { $0.id == repo.id })
      {
        repos[index].nameWithOwner = slug
        saveState()
      }
      // A worktree removed outside Yatty takes its terminals and sessions with it.
      for worktree in gone { await endTerminals(of: worktree) }
    } catch {
      loadErrors[repo.id] = error.localizedDescription
    }
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

  /// A local folder: errors show as an alert.
  func addRepository(at path: String) async {
    do {
      try await addRepository(path: path)
    } catch {
      alert = AppAlert(title: "Not a git repository", message: error.localizedDescription)
    }
  }

  /// Adds the repository `path` is in (or selects it if it's there already)
  /// and selects its main copy.
  func addRepository(path: String, nameWithOwner: String? = nil) async throws {
    let root = canonicalPath(try await Git.mainRoot(containing: path))
    var slug = nameWithOwner
    if slug == nil { slug = await Git.remoteSlug(root: root) }
    if let index = repos.firstIndex(where: { $0.id == root }) {
      if repos[index].nameWithOwner == nil, let slug {
        repos[index].nameWithOwner = slug
        saveState()
      }
    } else {
      repos.append(Repo(path: root, name: URL(fileURLWithPath: root).lastPathComponent, nameWithOwner: slug))
      saveState()
    }
    guard let repo = repos.first(where: { $0.id == root }) else { return }
    await refresh(repo)
    selection = worktrees[repo.id]?.first?.id
  }

  /// A repository picked from GitHub: selected if it's added already, else
  /// cloned into `<cloneDirectory>/<name>` — or that folder reused when it
  /// already holds the same repository — and added.
  func addRemote(_ remote: RemoteRepo) async throws {
    if let existing = repos.first(where: { $0.nameWithOwner?.lowercased() == remote.nameWithOwner.lowercased() }) {
      await refresh(existing)
      selection = worktrees[existing.id]?.first?.id
      return
    }
    let destination = config.cloneRoot.appendingPathComponent(remote.name).path
    if FileManager.default.fileExists(atPath: destination) {
      let origin = (try? await Git.run(["remote", "get-url", "origin"], in: destination)) ?? ""
      guard Git.remoteMatches(origin, nameWithOwner: remote.nameWithOwner) else {
        throw GitError(message: "\(destination) already holds another repository.")
      }
    } else {
      try FileManager.default.createDirectory(at: config.cloneRoot, withIntermediateDirectories: true)
      try await GitHub.clone(remote.nameWithOwner, to: destination)
    }
    try await addRepository(path: destination, nameWithOwner: remote.nameWithOwner)
  }

  /// Forgets the repository and ends its terminals' sessions; files stay.
  func removeRepository(_ repo: Repo) async {
    let list = worktrees[repo.id] ?? []
    if list.contains(where: { $0.id == selection }) { selection = nil }
    repos.removeAll { $0.id == repo.id }
    worktrees[repo.id] = nil
    loadErrors[repo.id] = nil
    // A repository that never loaded has no list; the next refresh reaps its sessions.
    for worktree in list { await endTerminals(of: worktree) }
    saveState()
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
  /// sessions. The branch stays.
  func closeWorktree(_ pending: PendingClose) async {
    let worktree = pending.worktree
    if selection == worktree.id { selection = worktrees[pending.repo.id]?.first?.id }
    await endTerminals(of: worktree)
    do {
      try await Git.removeWorktree(root: pending.repo.path, path: worktree.path)
    } catch {
      alert = AppAlert(title: "Couldn't close \(worktree.name)", message: error.localizedDescription)
    }
    await refresh(pending.repo)
  }

  func saveState() {
    ConfigFiles.saveState(StoredState(repos: repos, selectedWorktree: selection, layouts: layouts))
  }
}
