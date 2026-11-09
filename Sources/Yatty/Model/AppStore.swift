import AppKit
import Observation
import UserNotifications

struct PendingClose: Identifiable {
  let repo: Repo
  let worktree: Worktree
  var id: String { worktree.id }
}

/// The Add SSH Host sheet, maybe for a host already added.
struct AddHostRequest: Identifiable {
  let id = UUID()
  var host = ""
}

/// A merge to confirm: with a method picked (the PR panel's button), the
/// sheet opens at its confirm step; without (menus, palette) it asks for one.
struct MergeRequest: Identifiable {
  var worktree: Worktree
  var method: MergeMethod?
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
  /// SSH hosts and the directories on them, after the repositories.
  var hosts: [SSHHost] = []
  /// Remote sessions still to end; see `RemoteCleanup`.
  @ObservationIgnored var remoteCleanup: [RemoteCleanup] = []
  @ObservationIgnored private var cleaningUp = false
  /// Per repository path, main working copy first.
  var worktrees: [String: [Worktree]] = [:]
  var loadErrors: [String: String] = [:]
  var selection: String? {
    didSet {
      // Whatever selects a worktree (a jump to an agent, the palette, a new
      // one) shows its row, so its project unfolds.
      let unfolded =
        unfoldOnSelect ? selection.flatMap(projectID(of:)).map { foldedProjects.remove($0) != nil } ?? false : false
      guard selection != oldValue || unfolded else { return }
      if selection != oldValue { updateVisibility() }
      saveState()
    }
  }
  /// Sidebar repositories and hosts folded away, by `Repo.id` / `SSHHost.id`.
  var foldedProjects: Set<String> = []
  /// False while `select(_:unfolding:)` selects without unfolding.
  @ObservationIgnored private var unfoldOnSelect = true
  /// Per worktree path; see `layout(for:)`.
  var layouts: [String: WorktreeLayout] = [:]
  /// Per worktree path: a name the user gave it; see `label(for:)`.
  var labels: [String: String] = [:]
  /// Panes whose terminal couldn't start; they wait for "Try Again".
  var failedPanes: Set<PaneKey> = []
  /// Remote panes whose connection went; their session is still there.
  var disconnectedPanes: Set<PaneKey> = []
  /// What each pane's terminal calls itself (OSC 0/2).
  var paneTitles: [PaneKey: String] = [:]
  /// Bumped when a terminal finishes starting, so views asking for it look again.
  var terminalsStarted = 0

  var alert: AppAlert?
  var addingRepository = false
  var newWorktreeRepo: Repo?
  var pendingClose: PendingClose?
  var pendingRemoval: Repo?
  var addingHost: AddHostRequest?
  var showingPalette = false
  var showingHelp = false
  /// Asks the window to open Settings (only a view can).
  var openingSettings = false
  /// What the palette picked, run once it has closed.
  @ObservationIgnored var pickedCommand: Command?
  var pendingHostRemoval: SSHHost?
  var pendingDirectoryRemoval: Worktree?
  /// Being renamed in place in the sidebar; its row has to be there to show it.
  var renamingWorktree: Worktree? {
    didSet {
      guard let worktree = renamingWorktree else { return }
      if let project = projectID(of: worktree.id) { foldedProjects.remove(project) }
      if !sidebarFilter.isEmpty { sidebarFilter = "" }
    }
  }
  /// The sidebar's filter; not saved.
  var sidebarFilter = Snapshot.filter ?? ""
  /// Asks the sidebar to put the keyboard in its filter (only a view can).
  var focusingFilter = false

  /// `config.json`, as the Settings window last changed it.
  private(set) var config = ConfigFiles.loadConfig()
  var settingsError: String?
  let catalog = RepoCatalog()
  let agents = AgentMonitor()
  let gitStatus = GitStatusMonitor()
  let pullRequests = PullRequestStore()
  var showingPullRequest = Snapshot.sheet?.hasPrefix("pr-") == true
  /// The merge sheet's subject; see `MergeRequest`.
  var mergeRequest: MergeRequest?
  /// Per worktree: the PR panel's tab. Not saved.
  var prTabs: [String: PullRequestTab] = [:]
  /// The worktree whose pull request comments are being picked for the agent.
  var reviewingComments: Worktree?
  var mergeMethod: MergeMethod?
  var diffViewer: DiffViewer?
  var diffingWorktree: Worktree?
  @ObservationIgnored private let notificationDelegate = NotificationDelegate()
  /// "Track every claude": Yatty's hooks are in Claude's own settings.
  var trackingEveryClaude = ClaudeSettings.isInstalled()
  var confirmingTracking = false
  @ObservationIgnored var terminals: [PaneKey: TerminalView] = [:]
  @ObservationIgnored var starting: Set<PaneKey> = []
  /// Panes opened with "New Agent": their new session gets the agent command.
  @ObservationIgnored var agentPanes: Set<PaneKey> = []
  /// Panes opened on request (a diff, `yatty tab new`), until they start.
  @ObservationIgnored var paneLaunches: [PaneKey: PaneLaunch] = [:]
  /// The `yatty` CLI's sockets.
  @ObservationIgnored var cliServers: [CLIServer] = []
  /// Worktrees being closed or removed: no terminal may start for them.
  @ObservationIgnored var retiring: Set<String> = []
  @ObservationIgnored var focusWhenStarted: PaneKey?
  @ObservationIgnored private var excludeChecked: Set<String> = []

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
      labels = stored.labels
      foldedProjects = Set(stored.foldedProjects)
      mergeMethod = stored.mergeMethod
      diffViewer = stored.diffViewer
      hosts = stored.hosts
      remoteCleanup = stored.remoteCleanup
      reposKnown = true
    case .unreadable(let aside):
      repos = []
      reposKnown = false
      alert = AppAlert(
        title: "Couldn't read Yatty's state",
        message: "It was moved to \(aside.path). Add your repositories again; their terminals are still running.")
    }
    AgentHooks.install()
    agents.start(store: self)
    gitStatus.start(store: self)
    pullRequests.start(store: self)
    notificationDelegate.store = self
    startCLIServers()
    if !Snapshot.isActive { UNUserNotificationCenter.current().delegate = notificationDelegate }
    Task { await refreshAll() }
    if Snapshot.sheet == "add-repository" { addingRepository = true }
    if Snapshot.sheet == "add-host" { addingHost = AddHostRequest() }
    if Snapshot.sheet == "palette" { showingPalette = true }
    if Snapshot.sheet == "help" { showingHelp = true }
    if Snapshot.sheet == "settings" { openingSettings = true }
    if Snapshot.sheet == "sidebar-rename" {
      Task {
        await refreshAll()
        renamingWorktree = selectedWorktree
      }
    }
    if Snapshot.sheet == "disconnected", let selection {
      disconnectedPanes.insert(PaneKey(worktree: selection, pane: "0"))
    }
    if Snapshot.sheet == "diff" {
      Task {
        await refreshAll()
        diffingWorktree = selectedWorktree
      }
    }
    if Snapshot.sheet == "merge" || Snapshot.sheet == "review-comments" {
      Task {
        await refreshAll()
        try? await Task.sleep(for: .seconds(1))
        if let worktree = selectedWorktree, let repo = repo(of: worktree) {
          pullRequests.refreshDetails(for: worktree, in: repo)
          try? await Task.sleep(for: .milliseconds(500))
          if Snapshot.sheet == "merge" {
            mergeRequest = MergeRequest(worktree: worktree, method: nil)
          } else {
            reviewingComments = worktree
          }
        }
      }
    }
    if Snapshot.sheet?.hasPrefix("new-worktree") == true {
      Task {
        await refreshAll()
        newWorktreeForSelection()
      }
    }
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
      ?? hosts.lazy.flatMap(\.worktrees).first { $0.id == id }
  }

  func host(of worktree: Worktree) -> SSHHost? {
    worktree.host.flatMap { name in hosts.first { $0.host == name } }
  }

  func repo(of worktree: Worktree) -> Repo? {
    repos.first { worktrees[$0.id]?.contains(worktree) == true }
  }

  /// The repository or host a worktree is listed under in the sidebar.
  func projectID(of worktreeID: String) -> String? {
    guard let worktree = worktree(withID: worktreeID) else { return nil }
    return repo(of: worktree)?.id ?? host(of: worktree)?.id
  }

  /// Selects a worktree; `unfolding: false` leaves its project folded as it is.
  func select(_ id: String?, unfolding: Bool) {
    unfoldOnSelect = unfolding
    selection = id
    unfoldOnSelect = true
  }

  /// Drops a repository onto another, or a host onto another host: it takes
  /// that one's place.
  func moveProject(_ id: String, onto target: String) {
    reorderProjects { Self.moved($0, id, onto: target) }
  }

  /// One place up (-1) or down (+1) among its kind.
  func shiftProject(_ id: String, by delta: Int) {
    reorderProjects { Self.shifted($0, id, by: delta) }
  }

  func shiftSelectedProject(by delta: Int) {
    if let id = selection.flatMap(projectID(of:)) { shiftProject(id, by: delta) }
  }

  private func reorderProjects(_ reorder: ([String]) -> [String]?) {
    if let order = reorder(repos.map(\.id)) {
      repos = order.compactMap { id in repos.first { $0.id == id } }
    } else if let order = reorder(hosts.map(\.id)) {
      hosts = order.compactMap { id in hosts.first { $0.id == id } }
    } else {
      return
    }
    saveState()
  }

  /// `ids` with `id` at `target`'s place; nil when either isn't in it.
  nonisolated static func moved(_ ids: [String], _ id: String, onto target: String) -> [String]? {
    guard id != target, let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target) else { return nil }
    var order = ids
    order.remove(at: from)
    order.insert(id, at: to)
    return order
  }

  /// `ids` with `id` moved `delta` places; nil past either end.
  nonisolated static func shifted(_ ids: [String], _ id: String, by delta: Int) -> [String]? {
    guard let from = ids.firstIndex(of: id), ids.indices.contains(from + delta), delta != 0 else { return nil }
    return moved(ids, id, onto: ids[from + delta])
  }

  func toggleFold(_ projectID: String) {
    if foldedProjects.remove(projectID) == nil { foldedProjects.insert(projectID) }
    saveState()
  }

  // MARK: Loading

  func refreshAll() async {
    for repo in repos { await refresh(repo) }
    await reapOrphanSessions()
    await retryRemoteCleanup()
    gitStatus.refresh()
    pullRequests.refreshAll()
  }

  /// An agent changed state: it has probably just edited or pushed.
  func agentStatesChanged(in worktreeIDs: Set<String>) {
    gitStatus.refresh()
    for repo in repos {
      for worktree in worktrees[repo.id] ?? [] where worktreeIDs.contains(worktree.id) {
        pullRequests.refresh(worktree, in: repo)
      }
    }
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
    // `.worktrees/` must not make the main copy look dirty, however its
    // worktrees were made (once per repository per launch).
    if excludeChecked.insert(repo.id).inserted { await Git.ignoreWorktreesDir(root: repo.path) }
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

  // MARK: SSH hosts

  /// Checks the directory on the host and adds it (and the host, the first
  /// time), selected. What went wrong otherwise: a password to ask for, or
  /// why it can't be added.
  func addRemoteDirectory(host name: String, path: String, password: String?) async -> ProbeFailure? {
    let name = name.trimmingCharacters(in: .whitespaces)
    let path = path.trimmingCharacters(in: .whitespaces).isEmpty ? "~" : path.trimmingCharacters(in: .whitespaces)
    let found: RemoteDirectory
    switch await SSH.probe(host: name, path: path, password: password) {
    case .success(let directory): found = directory
    case .failure(let failure): return failure
    }
    if let index = hosts.firstIndex(where: { $0.host == name }) {
      hosts[index].home = found.home
      hosts[index].zmx = found.zmx
      if password != nil { hosts[index].needsPassword = true }
      if !hosts[index].directories.contains(found.path) { hosts[index].directories.append(found.path) }
    } else {
      hosts.append(
        SSHHost(host: name, home: found.home, zmx: found.zmx, needsPassword: password != nil, directories: [found.path]))
    }
    selection = SSHHost.directoryID(host: name, path: found.path)
    saveState()
    focusSelectedTerminal()
    return nil
  }

  /// Forgets the directory and ends its sessions on the host (now, or once
  /// it can be reached); its files stay. A host left with none goes too.
  func removeRemoteDirectory(_ worktree: Worktree) async {
    guard hosts.contains(where: { $0.host == worktree.host }) else { return }
    if selection == worktree.id { selection = nil }
    await endTerminals(of: worktree)
    // Found again: the list may have changed while the host was asked.
    guard let index = hosts.firstIndex(where: { $0.host == worktree.host }) else { return }
    hosts[index].directories.removeAll { $0 == worktree.path }
    if hosts[index].directories.isEmpty { hosts.remove(at: index) }
    saveState()
  }

  /// Ends the sessions a host couldn't be asked to end before. A password
  /// host is only asked over a connection that's already up.
  func retryRemoteCleanup() async {
    guard !cleaningUp, !remoteCleanup.isEmpty, !Snapshot.isActive else { return }
    cleaningUp = true
    defer { cleaningUp = false }
    for entry in remoteCleanup {
      let host = SSHHost(host: entry.host, home: "", zmx: entry.zmx, needsPassword: entry.needsPassword)
      if await SSH.kill(entry.sessions, on: host) {
        remoteCleanup.removeAll { $0 == entry }
        saveState()
      }
    }
  }

  func forgetCleanup(of session: String, on host: SSHHost) {
    guard remoteCleanup.contains(where: { $0.host == host.host && $0.sessions.contains(session) }) else { return }
    for index in remoteCleanup.indices where remoteCleanup[index].host == host.host {
      remoteCleanup[index].sessions.removeAll { $0 == session }
    }
    remoteCleanup.removeAll { $0.sessions.isEmpty }
    saveState()
  }

  /// Sessions `host` couldn't be asked to end now, for `retryRemoteCleanup`.
  func remember(_ sessions: [String], toEndOn host: SSHHost) {
    if let index = remoteCleanup.firstIndex(where: { $0.host == host.host && $0.zmx == host.zmx }) {
      remoteCleanup[index].sessions = Array(Set(remoteCleanup[index].sessions + sessions)).sorted()
    } else {
      remoteCleanup.append(
        RemoteCleanup(host: host.host, zmx: host.zmx, needsPassword: host.needsPassword, sessions: sessions.sorted()))
    }
    saveState()
  }

  func removeHost(_ host: SSHHost) async {
    for worktree in host.worktrees { await removeRemoteDirectory(worktree) }
    hosts.removeAll { $0.host == host.host }
    saveState()
  }

  // MARK: Worktrees

  func newWorktreeForSelection() {
    newWorktreeRepo = selectedWorktree.flatMap(repo(of:)) ?? repos.first
  }

  func requestCloseSelected() {
    if let worktree = selectedWorktree { requestClose(worktree) }
  }

  /// Asks before closing a worktree, or removing a remote directory.
  func requestClose(_ worktree: Worktree) {
    if worktree.isRemote {
      pendingDirectoryRemoval = worktree
      return
    }
    guard !worktree.isMain, let repo = repo(of: worktree) else { return }
    pendingClose = PendingClose(repo: repo, worktree: worktree)
  }

  /// A worktree in `<repo>/.worktrees/<branch>` from what the user picked,
  /// opened with the keyboard in its terminal. A branch that has a worktree
  /// already gets that one selected instead.
  func createWorktree(in repo: Repo, choice: NewWorktreeChoice) async throws {
    await Git.ignoreWorktreesDir(root: repo.path)
    let local = Set(try await Git.listBranches(root: repo.path).local)
    let branch = choice.branch
    if let open = worktrees[repo.id]?.first(where: { $0.branch == branch }) {
      selection = open.id
      focusSelectedTerminal()
      return
    }
    let path = URL(fileURLWithPath: repo.path)
      .appendingPathComponent(".worktrees")
      .appendingPathComponent(choice.directoryName).path
    switch choice {
    case .newBranch(let name, let base):
      try await Git.addWorktree(root: repo.path, path: path, branch: name, base: base)
    case .existingBranch(let name):
      try await Git.addWorktree(root: repo.path, path: path, existingBranch: name)
    case .remoteBranch(let remote, let name):
      if local.contains(name) {
        try await Git.addWorktree(root: repo.path, path: path, existingBranch: name)
      } else {
        try await Git.addWorktree(root: repo.path, path: path, remote: remote, branch: name)
      }
    case .pullRequest(let pr):
      // Our own pull request's branch is already here; anything else is fetched.
      if pr.isCrossRepository || !local.contains(branch) {
        try await Git.fetchPullRequest(root: repo.path, number: pr.number, into: branch)
      }
      try await Git.addWorktree(root: repo.path, path: path, existingBranch: branch)
    }
    await refresh(repo)
    selection = canonicalPath(path)
    focusSelectedTerminal()
  }

  /// The sidebar's name for the worktree: its label, else its branch's.
  func label(for worktree: Worktree) -> String {
    labels[worktree.id] ?? worktree.name
  }

  /// Only the sidebar's name changes; an empty name gives back the branch's.
  func renameWorktree(_ worktree: Worktree, to name: String) {
    labels[worktree.id] = Self.cleanLabel(name, automatic: worktree.name)
    saveState()
  }

  /// A name as the sidebar keeps it: trimmed; nil — follow the branch — when
  /// empty or the branch's own name.
  nonisolated static func cleanLabel(_ name: String, automatic: String) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty || trimmed == automatic ? nil : trimmed
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

  // MARK: Pull requests

  func setDiffViewer(_ viewer: DiffViewer) {
    diffViewer = viewer
    saveState()
  }

  /// Badges, and the inspector's details, asked again now.
  func refreshPullRequests() {
    pullRequests.refreshAll(force: true)
    if let worktree = selectedWorktree, let repo = repo(of: worktree) {
      pullRequests.refreshDetails(for: worktree, in: repo)
      pullRequests.ensureMergeSettings(for: repo)
    }
  }

  /// The PR panel, open at `tab`.
  func showPullRequestTab(_ tab: PullRequestTab, for worktree: Worktree) {
    prTabs[worktree.id] = tab
    showingPullRequest = true
  }

  func openPullRequest(_ worktree: Worktree) {
    if let url = pullRequests.badge(for: worktree).flatMap({ URL(string: $0.url) }) { NSWorkspace.shared.open(url) }
  }

  /// The sidebar's sections on top, over `worktrees`: see `WorktreeSummary.activeSections`.
  func floatedSections(of worktrees: [Worktree]) -> [(state: AgentState, ids: [String])] {
    WorktreeSummary.activeSections(
      worktrees.compactMap { worktree in
        guard let state = agents.floatingState(of: worktree) else { return nil }
        return (worktree.id, state, agents.since(of: worktree, in: state) ?? .distantFuture)
      })
  }

  /// Re-runs the failed jobs of every Actions run with a failed check.
  func rerunFailedChecks(in worktree: Worktree) {
    for run in pullRequests.details[worktree.id].map(PullRequests.failedRuns) ?? [] { rerun(run, in: worktree) }
  }

  func rerun(_ run: ActionsRun, in worktree: Worktree) {
    guard !Snapshot.isActive else { return }
    Task {
      do {
        try await GitHub.rerunFailed(runID: run.runID, in: run.nameWithOwner)
        if let repo = repo(of: worktree) { pullRequests.refreshDetails(for: worktree, in: repo) }
      } catch {
        alert = AppAlert(title: "Couldn't re-run the checks", message: error.localizedDescription)
      }
    }
  }

  // MARK: Agents

  /// Shows the pane a notification is about: its worktree, tab, keyboard.
  func reveal(_ key: PaneKey) {
    guard worktree(withID: key.worktree) != nil else { return }
    selection = key.worktree
    focusPane(key)
  }

  /// The next worktree (in sidebar order, after the selected one) whose agent
  /// needs you, else is done; its pane gets the keyboard.
  func jumpToNextAgent() {
    let all = repos.flatMap { worktrees[$0.id] ?? [] }
    let order = WorktreeSummary.sidebarOrder(all.map(\.id), active: floatedSections(of: all))
    var states: [String: AgentState] = [:]
    for worktree in all { states[worktree.id] = agents.state(of: worktree) }
    guard let target = AgentMonitor.nextTarget(order: order, states: states, after: selection),
      let worktree = worktree(withID: target), let state = states[target],
      let pane = agents.pane(of: worktree, in: state)
    else { return }
    reveal(pane)
  }

  /// Turning tracking on asks first (`confirmingTracking`); off doesn't.
  func setTracking(_ on: Bool) {
    do {
      try ClaudeSettings.setInstalled(on)
      trackingEveryClaude = on
    } catch {
      alert = AppAlert(title: "Couldn't change Claude's settings", message: error.localizedDescription)
      trackingEveryClaude = ClaudeSettings.isInstalled()
    }
  }

  /// Settings apply at once: to terminals started from now on, the next
  /// clone, the next notification.
  func applySettings(_ draft: YattyConfig) {
    // What applies now is what the file will say: a cleared clone folder is
    // the default one, never "/".
    let settings = draft.normalized
    guard settings != config else { return }
    config = settings
    do {
      try ConfigFiles.saveConfig(settings)
      settingsError = nil
    } catch {
      settingsError = "Couldn't save the settings: \(error.localizedDescription)"
    }
  }

  func saveState() {
    ConfigFiles.saveState(
      StoredState(
        repos: repos, selectedWorktree: selection, layouts: layouts, labels: labels,
        foldedProjects: foldedProjects.sorted(), mergeMethod: mergeMethod,
        diffViewer: diffViewer, hosts: hosts, remoteCleanup: remoteCleanup))
  }
}
