import CryptoKit
import Foundation

/// zmx keeps each terminal's shell alive when Yatty quits. Yatty's sessions
/// live on their own socket directory, apart from any zmx the user runs.
enum Zmx {
  static var executable: String {
    Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("zmx").path
  }

  /// `YATTY_ZMX_DIR` moves it, so snapshots and tests never meet real sessions.
  static let socketDir: String = {
    let override = ProcessInfo.processInfo.environment["YATTY_ZMX_DIR"] ?? ""
    let dir = override.hasPrefix("/")
      ? override
      : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/yatty/zmx").path
    try? FileManager.default.createDirectory(
      atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return dir
  }()

  static var environment: [String: String] {
    [
      "ZMX_DIR": socketDir,
      // ctrl+\ would detach the terminal from its session; let programs have it.
      "ZMX_NO_DETACH_KEY": "1",
    ]
  }

  /// A stable session name per worktree directory.
  static func sessionName(for worktreePath: String) -> String {
    let digest = SHA256.hash(data: Data(worktreePath.utf8))
    return "yatty-" + digest.prefix(5).map { String(format: "%02x", $0) }.joined()
  }

  /// Pane `0` is the worktree's first terminal and keeps the plain name.
  static func sessionName(for worktreePath: String, pane: String) -> String {
    let base = sessionName(for: worktreePath)
    return pane == "0" ? base : base + "-" + pane
  }

  /// Every session a known worktree may own: its first pane's, whether or not
  /// it was opened, and every pane of its stored layout.
  static func knownSessions(worktrees: [Worktree], layouts: [String: WorktreeLayout]) -> Set<String> {
    var known = Set<String>()
    for worktree in worktrees {
      known.insert(sessionName(for: worktree.path))
      for pane in layouts[worktree.path]?.allPanes ?? [] {
        known.insert(sessionName(for: worktree.path, pane: pane))
      }
    }
    return known
  }

  /// Yatty's live sessions, or nil when zmx couldn't be asked.
  static func sessions() async -> Set<String>? {
    let result = await Run.run(executable, ["list", "--short"], env: environment)
    guard result.ok else { return nil }
    return Set(result.stdout.split(separator: "\n").compactMap { $0.split(separator: " ").first.map(String.init) })
  }

  static func kill(_ name: String) async {
    _ = await Run.run(executable, ["kill", name], env: environment)
  }

  /// The terminal's command: attach to the session, starting the login shell
  /// in it if it doesn't exist yet. libghostty runs it as
  /// `bash -c "exec -l <command>"`, so it's plain shell words.
  static func attachCommand(session: String) -> String {
    [executable, "attach", session, loginShell, "-l"].map(shellQuote).joined(separator: " ")
  }

  static var loginShell: String {
    if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
      let path = String(cString: shell)
      if !path.isEmpty { return path }
    }
    return "/bin/zsh"
  }
}
