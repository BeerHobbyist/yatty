import Foundation
import YattyProtocol

/// SSH projects: a host whose directories open as terminals on that machine,
/// in zmx there, so shells outlive the connection. Yatty runs only shells and
/// zmx over ssh; no git (agentree's src/services/ssh.ts).
///
/// Every call shares one master connection per host (`ControlMaster`), so a
/// new pane or a session check reuses it instead of a new handshake.
/// How Yatty runs ssh: the program, where the shared connections' sockets
/// go (nil: no sharing), and anything added to its environment. Tests swap
/// in a fake.
struct SSHSetup: Sendable {
  var executable = "/usr/bin/ssh"
  var controlDirectory: String?
  var environment: [String: String] = [:]

  /// `$YATTY_SSH` stands in for ssh (the end-to-end run's, with its own config).
  static var standard: SSHSetup {
    let override = ProcessInfo.processInfo.environment["YATTY_SSH"] ?? ""
    return SSHSetup(executable: override.hasPrefix("/") ? override : "/usr/bin/ssh", controlDirectory: SSH.controlDirectory())
  }

  /// Options for every call: one shared master connection per host.
  var sharingOptions: [String] {
    guard let controlDirectory else { return [] }
    return [
      "-o", "ControlMaster=auto", "-o", "ControlPath=\(controlDirectory)/%C", "-o", "ControlPersist=10m",
    ]
  }

  func run(_ argv: [String], env: [String: String] = [:], timeout: TimeInterval) async -> ProcessResult {
    await Run.run(argv[0], Array(argv.dropFirst()), env: environment.merging(env) { _, new in new }, timeout: timeout)
  }
}

enum SSH {
  /// Something to hand ssh as a destination: a `~/.ssh/config` alias,
  /// `user@host`, or `ssh://user@host:port`. Never an option (`-o…`).
  static func isValidHost(_ host: String) -> Bool {
    guard let first = host.first, first != "-" else { return false }
    return !host.contains { $0.isWhitespace || $0.isNewline }
  }

  // MARK: The shared connection

  /// A socket path's limit on macOS, its terminating NUL left out.
  static let maxSocketPath = 103
  /// What ssh makes of `<dir>/%C` while it binds: `/`, 40 hex digits, and a
  /// temporary `.` plus 16 random characters, renamed away once bound.
  static let controlNameLength = 1 + 40 + 17

  /// Where the per-host master connections' sockets live: the first
  /// candidate short enough, and ours and private. None: no sharing.
  static func controlDirectory(candidates: [String]? = nil) -> String? {
    let uid = getuid()
    let dirs = candidates ?? [
      CLIPaths.directory().appendingPathComponent("ssh").path,
      "/tmp/yatty-ssh-\(uid)",
    ]
    for dir in dirs where dir.utf8.count + controlNameLength <= maxSocketPath {
      try? FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      // In a shared place (/tmp), only a directory that's ours and private will do.
      var info = stat()
      guard lstat(dir, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == uid,
        info.st_mode & 0o077 == 0
      else { continue }
      return dir
    }
    return nil
  }

  /// The argv that runs a POSIX shell command line on `host`. sshd hands it
  /// to the user's login shell, which may be fish, so it's wrapped in
  /// `sh -c`, quoted so that fish reads it as sh does. `tty`: an interactive terminal, where ssh can ask for a
  /// password or a host key; otherwise batch mode, failing fast instead of
  /// waiting on a prompt nobody sees.
  static func argv(host: String, command: String, tty: Bool, setup: SSHSetup = .standard) -> [String] {
    let mode = tty ? ["-t", "-o", "ConnectTimeout=10"] : ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
    return [setup.executable] + setup.sharingOptions + mode + ["--", host, "exec sh -c " + CLIRules.portableQuote(command)]
  }

  /// A remote path as a shell word: a leading `~` becomes `"$HOME"`
  /// (quoted, the shell wouldn't expand it); the rest is quoted.
  static func remotePathExpr(_ path: String) -> String {
    if path == "~" { return #""$HOME""# }
    if path.hasPrefix("~/") { return #""$HOME"/"# + shellQuote(String(path.dropFirst(2))) }
    return shellQuote(path)
  }

  /// A remote path for display: under the remote home, `~/…`.
  static func displayPath(_ path: String, home: String?) -> String {
    guard let home, !home.isEmpty, home != "/" else { return path }
    if path == home { return "~" }
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
  }

  // MARK: Hosts the user has

  /// Hosts named in `~/.ssh/config` (`Host` lines, without patterns), as
  /// suggestions. `$YATTY_SSH_CONFIG` points elsewhere (tests).
  static func configuredHosts() -> [String] {
    let override = ProcessInfo.processInfo.environment["YATTY_SSH_CONFIG"] ?? ""
    let file = override.hasPrefix("/")
      ? override
      : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config").path
    return parseConfigHosts((try? String(contentsOfFile: file, encoding: .utf8)) ?? "")
  }

  static func parseConfigHosts(_ text: String) -> [String] {
    var hosts: [String] = []
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
      let words = line.split(whereSeparator: \.isWhitespace)
      guard words.first?.lowercased() == "host" else { continue }
      for name in words.dropFirst().map(String.init)
      where !name.contains(where: { "*?!".contains($0) }) && !hosts.contains(name) {
        hosts.append(name)
      }
    }
    return hosts
  }

  // MARK: Logging in

  /// The `SSH_ASKPASS` program: answers ssh's password prompt (`…'s
  /// password: `, `Password:`) or key passphrase prompt (`Enter passphrase
  /// for …`) with the secret in its environment, and refuses anything else:
  /// a host-key question or a one-time code mustn't get the password, even
  /// when a host or key is named "password". It holds no secret itself.
  static let askpassScript = """
    #!/bin/sh
    case "$1" in
      *"(yes/no"*|*[Ff]ingerprint*|*[Oo]ne-[Tt]ime*|*OTP*|*[Cc]ode*|*[Tt]oken*) exit 1 ;;
      "Enter passphrase for "*|*"'s password: "|*[Pp]assword:|*[Pp]assword:" ") printf '%s\\n' "$YATTY_SSH_SECRET" ;;
      *) exit 1 ;;
    esac

    """

  /// Writes the askpass program where only this user can reach it.
  static func askpassHelper(in directory: String?) -> String? {
    guard let directory else { return nil }
    let path = directory + "/askpass"
    guard FileManager.default.createFile(
      atPath: path, contents: Data(askpassScript.utf8), attributes: [.posixPermissions: 0o700])
    else { return nil }
    return path
  }

  /// ssh's complaint, with what to do about the usual ones.
  static func connectError(host: String, stderr: String) -> String {
    let last = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "ssh to \(host) failed"
    if stderr.localizedCaseInsensitiveContains("Host key verification failed") {
      return "\(last). Run `ssh \(host)` once in a terminal to check and accept its host key."
    }
    return last
  }

  /// Whether a shared connection to `host` is up. Local: nothing is sent to
  /// the host.
  static func isConnected(host: String, setup: SSHSetup = .standard) async -> Bool {
    guard !setup.sharingOptions.isEmpty else { return false }
    return await setup.run([setup.executable] + setup.sharingOptions + ["-O", "check", "--", host], timeout: 5).ok
  }
}
