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
  /// hook is Yatty's when its command mentions `YATTY_AGENT_DIR`. Anything
  /// shaped in a way Yatty doesn't expect is kept exactly as it was.
  static func merging(_ settings: [String: Any], install: Bool) -> [String: Any] {
    if let other = settings["hooks"], !(other is [String: Any]) { return settings }
    var result = settings
    var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
    for (event, value) in hooks {
      guard let entries = value as? [Any] else { continue }
      let kept = entries.compactMap { item -> Any? in
        guard let entry = item as? [String: Any], let commands = entry["hooks"] as? [Any] else { return item }
        let others = commands.filter { command in
          !((command as? [String: Any])?["command"] as? String ?? "").contains("YATTY_AGENT_DIR")
        }
        if others.count == commands.count { return item }
        guard !others.isEmpty else { return nil }
        var copy = entry
        copy["hooks"] = others
        return copy
      }
      hooks[event] = kept.isEmpty ? nil : kept
    }
    if install, let ours = AgentHooks.settings()["hooks"] as? [String: [[String: Any]]] {
      for (event, entries) in ours {
        guard let existing = hooks[event] else {
          hooks[event] = entries
          continue
        }
        // An event whose value isn't a list isn't Yatty's to touch.
        if let list = existing as? [Any] { hooks[event] = list + entries }
      }
    }
    result["hooks"] = hooks.isEmpty ? nil : hooks
    return result
  }

  static func isInstalled() -> Bool {
    guard let settings = read() else { return false }
    let hooks = (settings["hooks"] as? [String: Any]) ?? [:]
    return hooks.values.contains { value in
      ((value as? [Any]) ?? []).contains { entry in
        (((entry as? [String: Any])?["hooks"] as? [Any]) ?? []).contains {
          (($0 as? [String: Any])?["command"] as? String ?? "").contains("YATTY_AGENT_DIR")
        }
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
      withJSONObject: merging(settings, install: on), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    // Through a symlink (dotfiles repos link it), not over it.
    let target = url.resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: target, options: .atomic)
  }

  private static func read() -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }
}
