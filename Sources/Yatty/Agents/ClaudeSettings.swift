import Foundation

/// "Track every claude": Yatty's status hooks in the user's own Claude
/// settings, so a `claude` typed by hand reports too. They do nothing outside
/// a Yatty terminal; other hooks and settings are left as they are.
enum ClaudeSettings {
  static var url: URL {
    let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? ""
    let base = dir.hasPrefix("/")
      ? URL(fileURLWithPath: dir)
      : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    return base.appendingPathComponent("settings.json")
  }

  /// `settings` without Yatty's hooks, then (with `install`) with them. A
  /// hook is Yatty's when its command mentions `YATTY_AGENT_DIR`.
  static func merging(_ settings: [String: Any], install: Bool) -> [String: Any] {
    var result = settings
    var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
    for (event, value) in hooks {
      let entries = (value as? [[String: Any]]) ?? []
      let kept = entries.compactMap { entry -> [String: Any]? in
        let commands = (entry["hooks"] as? [[String: Any]]) ?? []
        let others = commands.filter { !(($0["command"] as? String) ?? "").contains("YATTY_AGENT_DIR") }
        guard !others.isEmpty else { return nil }
        var copy = entry
        copy["hooks"] = others
        return copy
      }
      hooks[event] = kept.isEmpty ? nil : kept
    }
    if install, let ours = AgentHooks.settings()["hooks"] as? [String: [[String: Any]]] {
      for (event, entries) in ours {
        hooks[event] = ((hooks[event] as? [[String: Any]]) ?? []) + entries
      }
    }
    result["hooks"] = hooks.isEmpty ? nil : hooks
    return result
  }

  static func isInstalled() -> Bool {
    guard let settings = read() else { return false }
    let hooks = (settings["hooks"] as? [String: [[String: Any]]]) ?? [:]
    return hooks.values.joined().contains { entry in
      ((entry["hooks"] as? [[String: Any]]) ?? []).contains {
        (($0["command"] as? String) ?? "").contains("YATTY_AGENT_DIR")
      }
    }
  }

  /// A settings file that isn't valid JSON is left alone.
  static func setInstalled(_ on: Bool) throws {
    var settings: [String: Any] = [:]
    if FileManager.default.fileExists(atPath: url.path) {
      guard let existing = read() else {
        throw GitError(message: "\(url.path) isn't valid JSON, so Yatty left it alone.")
      }
      settings = existing
    }
    let data = try JSONSerialization.data(
      withJSONObject: merging(settings, install: on), options: [.prettyPrinted, .sortedKeys])
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  }

  private static func read() -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }
}
