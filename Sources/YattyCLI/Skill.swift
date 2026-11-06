import Foundation

/// `yatty skill install|uninstall|show`: the Claude Code skill that teaches
/// agents this CLI, shipped in the app bundle beside it.
enum Skill {
  static func run(_ arguments: [String], environment: [String: String]) -> Int32 {
    // The executable itself: argv[0] is just "yatty" when found on PATH.
    let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let bundled = executable.resolvingSymlinksInPath()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("skills/yatty/SKILL.md")
    let configDir = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    let installed = configDir.appendingPathComponent("skills/yatty")
    switch arguments.first {
    case "show":
      guard let text = try? String(contentsOf: bundled, encoding: .utf8) else { return report("the skill isn't in this build") }
      print(text, terminator: "")
      return 0
    case "install":
      do {
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        let target = installed.appendingPathComponent("SKILL.md")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: bundled, to: target)
        print("installed -> \(target.path)")
        return 0
      } catch {
        return report("couldn't install the skill: \(error.localizedDescription)")
      }
    case "uninstall":
      try? FileManager.default.removeItem(at: installed)
      print("removed \(installed.path)")
      return 0
    default:
      return report("usage: yatty skill install|uninstall|show")
    }
  }

  private static func report(_ message: String) -> Int32 {
    FileHandle.standardError.write(Data("yatty: \(message)\n".utf8))
    return 1
  }
}
