import Foundation

struct Repo: Codable, Identifiable, Hashable {
  /// The main working copy, symlinks resolved.
  var path: String
  var name: String

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
}

/// Settings the user edits: `~/.config/yatty/config.json`.
struct YattyConfig: Codable {
  /// Typed into a worktree's terminal when its session is first created.
  var agentCommand: String = "caffeinate -is claude"

  enum CodingKeys: String, CodingKey { case agentCommand }

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    agentCommand = try container.decodeIfPresent(String.self, forKey: .agentCommand) ?? agentCommand
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
