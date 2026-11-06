import Foundation

struct Repo: Codable, Identifiable, Hashable {
  /// The main working copy, symlinks resolved.
  var path: String
  var name: String
  /// `owner/name` on GitHub, when known: pull requests need it.
  var nameWithOwner: String?

  var id: String { path }
}

struct Worktree: Identifiable, Hashable {
  /// Symlinks resolved, as git reports it; on a host, its absolute path there.
  let path: String
  /// nil when detached.
  let branch: String?
  let head: String?
  /// The repository's main working copy, which can't be closed.
  let isMain: Bool
  /// The SSH host it's on; nil on this Mac.
  var host: String? = nil

  var id: String { host.map { SSHHost.directoryID(host: $0, path: path) } ?? path }

  var isRemote: Bool { host != nil }

  /// What its zmx session names are made from: the path here; on a host, the
  /// host too, so two names for one machine never share a session.
  var sessionKey: String { isRemote ? id : path }

  /// The branch's last segment (feature/login → login), else the directory.
  var name: String {
    if let branch, let leaf = branch.split(separator: "/").last { return String(leaf) }
    return URL(fileURLWithPath: path).lastPathComponent
  }

  /// A remote directory is taken to exist: only the host could say.
  var exists: Bool { isRemote || FileManager.default.fileExists(atPath: path) }
}

/// Sessions to end on a host that couldn't be reached when their pane,
/// directory or host went: tried again whenever Yatty refreshes.
struct RemoteCleanup: Codable, Hashable {
  var host: String
  var zmx: String
  var needsPassword: Bool
  var sessions: [String]
}

/// An SSH host and the directories on it the user added.
struct SSHHost: Codable, Identifiable, Hashable {
  /// What ssh is given: a `~/.ssh/config` alias, `user@host`…
  var host: String
  /// The remote user's `$HOME`, to show paths as `~/…`.
  var home: String
  /// zmx's absolute path there, found when the host was added.
  var zmx: String
  /// It logged in with a password (or a key's passphrase): background calls
  /// wait for a live shared connection.
  var needsPassword = false
  /// Absolute paths there.
  var directories: [String] = []

  var id: String { "ssh:" + host }

  init(host: String, home: String, zmx: String, needsPassword: Bool = false, directories: [String] = []) {
    self.host = host
    self.home = home
    self.zmx = zmx
    self.needsPassword = needsPassword
    self.directories = directories
  }

  // Only the host is needed: a field missing from an older or hand-edited
  // state.json mustn't cost the whole file.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    host = try container.decode(String.self, forKey: .host)
    home = try container.decodeIfPresent(String.self, forKey: .home) ?? ""
    zmx = try container.decodeIfPresent(String.self, forKey: .zmx) ?? "zmx"
    needsPassword = try container.decodeIfPresent(Bool.self, forKey: .needsPassword) ?? false
    directories = try container.decodeIfPresent([String].self, forKey: .directories) ?? []
  }

  static func directoryID(host: String, path: String) -> String { "ssh:\(host):\(path)" }

  var worktrees: [Worktree] {
    directories.map { Worktree(path: $0, branch: nil, head: nil, isMain: false, host: host) }
  }
}

/// What Yatty remembers between launches: `~/.config/yatty/state.json`.
struct StoredState: Codable {
  var repos: [Repo] = []
  var selectedWorktree: String?
  /// Per worktree path; a worktree without one has `WorktreeLayout.initial`.
  var layouts: [String: WorktreeLayout] = [:]
  /// Per worktree path: the name the sidebar shows instead of the branch's.
  var labels: [String: String] = [:]
  /// Pull request inspector sections the user folded.
  var foldedSections: [String] = []
  /// The merge method used last, offered first.
  var mergeMethod: MergeMethod?
  /// The diff viewer the user picked.
  var diffViewer: DiffViewer?
  var hosts: [SSHHost] = []
  var remoteCleanup: [RemoteCleanup] = []

  init(
    repos: [Repo] = [], selectedWorktree: String? = nil, layouts: [String: WorktreeLayout] = [:],
    labels: [String: String] = [:], foldedSections: [String] = [], mergeMethod: MergeMethod? = nil,
    diffViewer: DiffViewer? = nil, hosts: [SSHHost] = [], remoteCleanup: [RemoteCleanup] = []
  ) {
    self.hosts = hosts
    self.remoteCleanup = remoteCleanup
    self.diffViewer = diffViewer
    self.repos = repos
    self.selectedWorktree = selectedWorktree
    self.layouts = layouts
    self.labels = labels
    self.foldedSections = foldedSections
    self.mergeMethod = mergeMethod
  }

  // Every field may be missing: a file from an older Yatty must still load.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    repos = try container.decodeIfPresent([Repo].self, forKey: .repos) ?? []
    selectedWorktree = try container.decodeIfPresent(String.self, forKey: .selectedWorktree)
    layouts = try container.decodeIfPresent([String: WorktreeLayout].self, forKey: .layouts) ?? [:]
    labels = try container.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
    foldedSections = try container.decodeIfPresent([String].self, forKey: .foldedSections) ?? []
    mergeMethod = try? container.decodeIfPresent(MergeMethod.self, forKey: .mergeMethod)
    diffViewer = try? container.decodeIfPresent(DiffViewer.self, forKey: .diffViewer)
    hosts = try container.decodeIfPresent([SSHHost].self, forKey: .hosts) ?? []
    remoteCleanup = (try? container.decodeIfPresent([RemoteCleanup].self, forKey: .remoteCleanup)) ?? []
  }
}

/// Settings the user edits: `~/.config/yatty/config.json`.
struct YattyConfig: Codable, Equatable {
  /// Typed into a worktree's terminal when its session is first created.
  var agentCommand: String = "caffeinate -is claude"
  /// Where repositories picked from GitHub are cloned; `~` is the home folder.
  var cloneDirectory: String = "~/yatty"
  /// System notifications when an agent needs you or finishes elsewhere.
  var notifications: Bool = true
  /// What a sandboxed agent's `yatty tab new` runs in: a command prefix read
  /// by /bin/sh, like `fence --`. Unset, Yatty starts nothing for one.
  var sandboxCommand: String?

  enum CodingKeys: String, CodingKey { case agentCommand, cloneDirectory, notifications, sandboxCommand }

  init() {}

  // A value of the wrong type costs only itself, not the rest of the file.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    agentCommand = (try? container.decodeIfPresent(String.self, forKey: .agentCommand)) ?? agentCommand
    cloneDirectory = (try? container.decodeIfPresent(String.self, forKey: .cloneDirectory)) ?? cloneDirectory
    notifications = (try? container.decodeIfPresent(Bool.self, forKey: .notifications)) ?? notifications
    sandboxCommand = try? container.decodeIfPresent(String.self, forKey: .sandboxCommand)
    self = normalized
  }

  /// As it applies: a blank clone directory is the default one, a blank
  /// sandbox command is none, and surrounding spaces don't count.
  var normalized: YattyConfig {
    var settings = self
    let clone = cloneDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
    settings.cloneDirectory = clone.isEmpty ? YattyConfig().cloneDirectory : clone
    let sandbox = sandboxCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    settings.sandboxCommand = sandbox.isEmpty ? nil : sandbox
    return settings
  }

  var cloneRoot: URL {
    URL(fileURLWithPath: (cloneDirectory as NSString).expandingTildeInPath)
  }
}

enum ConfigFiles {
  static var directory: URL {
    let env = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? ""
    let base = env.hasPrefix("/")
      ? URL(fileURLWithPath: env)
      : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
    return base.appendingPathComponent("yatty")
  }

  static var state: URL { directory.appendingPathComponent("state.json") }
  static var config: URL { directory.appendingPathComponent("config.json") }

  enum LoadedState {
    case missing
    case loaded(StoredState)
    /// The file exists but couldn't be read; it was moved to `movedTo`.
    case unreadable(movedTo: URL)
  }

  static func loadState() -> LoadedState {
    guard FileManager.default.fileExists(atPath: state.path) else { return .missing }
    if let data = try? Data(contentsOf: state),
      let decoded = try? JSONDecoder().decode(StoredState.self, from: data)
    {
      return .loaded(decoded)
    }
    // Kept aside rather than overwritten by the next save.
    let aside = directory.appendingPathComponent("state.unreadable.json")
    try? FileManager.default.removeItem(at: aside)
    try? FileManager.default.moveItem(at: state, to: aside)
    return .unreadable(movedTo: aside)
  }

  static func saveState(_ value: StoredState) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value) else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: state, options: .atomic)
  }

  static func loadConfig() -> YattyConfig {
    guard let data = try? Data(contentsOf: config),
      let decoded = try? JSONDecoder().decode(YattyConfig.self, from: data)
    else { return YattyConfig() }
    return decoded
  }
}
