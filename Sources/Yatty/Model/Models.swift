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
  /// Symlinks resolved, as git reports it.
  let path: String
  /// nil when detached.
  let branch: String?
  let head: String?
  /// The repository's main working copy, which can't be closed.
  let isMain: Bool

  var id: String { path }

  /// The branch's last segment (feature/login → login), else the directory.
  var name: String {
    if let branch, let leaf = branch.split(separator: "/").last { return String(leaf) }
    return URL(fileURLWithPath: path).lastPathComponent
  }

  var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// What Yatty remembers between launches: `~/.config/yatty/state.json`.
struct StoredState: Codable {
  var repos: [Repo] = []
  var selectedWorktree: String?
  /// Per worktree path; a worktree without one has `WorktreeLayout.initial`.
  var layouts: [String: WorktreeLayout] = [:]
  /// Per worktree path: the name the sidebar shows instead of the branch's.
  var labels: [String: String] = [:]

  init(
    repos: [Repo] = [], selectedWorktree: String? = nil, layouts: [String: WorktreeLayout] = [:],
    labels: [String: String] = [:]
  ) {
    self.repos = repos
    self.selectedWorktree = selectedWorktree
    self.layouts = layouts
    self.labels = labels
  }

  // Every field may be missing: a file from an older Yatty must still load.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    repos = try container.decodeIfPresent([Repo].self, forKey: .repos) ?? []
    selectedWorktree = try container.decodeIfPresent(String.self, forKey: .selectedWorktree)
    layouts = try container.decodeIfPresent([String: WorktreeLayout].self, forKey: .layouts) ?? [:]
    labels = try container.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
  }
}

/// Settings the user edits: `~/.config/yatty/config.json`.
struct YattyConfig: Codable {
  /// Typed into a worktree's terminal when its session is first created.
  var agentCommand: String = "caffeinate -is claude"
  /// Where repositories picked from GitHub are cloned; `~` is the home folder.
  var cloneDirectory: String = "~/yatty"

  enum CodingKeys: String, CodingKey { case agentCommand, cloneDirectory }

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    agentCommand = try container.decodeIfPresent(String.self, forKey: .agentCommand) ?? agentCommand
    cloneDirectory = try container.decodeIfPresent(String.self, forKey: .cloneDirectory) ?? cloneDirectory
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
