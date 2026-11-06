import Foundation

/// A directory on a host, as the probe found it.
struct RemoteDirectory: Equatable, Sendable {
  /// Absolute, on the host.
  let path: String
  /// The remote user's `$HOME`.
  let home: String
  /// zmx's absolute path there.
  let zmx: String
}

enum ProbeFailure: Error, Equatable {
  /// The host wants a password, or the key's passphrase.
  case needsPassword(String)
  case failed(String)
}

extension SSH {
  /// What the probe runs there: into the directory (or exit 3), then where
  /// that is, `$HOME` and where zmx is, NUL-separated after a marker (a
  /// directory may hold a newline; a login script may print). A
  /// non-interactive ssh has a thin PATH, so the login shell is asked too.
  static func probeScript(path: String) -> String {
    [
      "cd -- \(remotePathExpr(path)) || exit 3",
      #"z=$(command -v zmx 2>/dev/null) || z=$("${SHELL:-/bin/sh}" -l -c 'command -v zmx' </dev/null 2>/dev/null | tail -n 1)"#,
      #"printf '\#(probeMarker)\0%s\0%s\0%s\0' "$PWD" "$HOME" "$z""#,
    ].joined(separator: "; ")
  }

  static let probeMarker = "yatty-probe"

  /// The probe's answer, or why the directory can't be added.
  static func parseProbe(status: Int32, stdout: String, stderr: String, host: String, path: String)
    -> Result<RemoteDirectory, ProbeFailure>
  {
    if status == 3 { return .failure(.failed("\(path) doesn't exist on \(host), or isn't a directory.")) }
    if status != 0 {
      if stderr.localizedCaseInsensitiveContains("Permission denied") {
        return .failure(.needsPassword(stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "Permission denied"))
      }
      return .failure(.failed(connectError(host: host, stderr: stderr)))
    }
    guard let start = stdout.range(of: probeMarker + "\0") else {
      return .failure(.failed("Couldn't read \(path) on \(host)."))
    }
    let fields = stdout[start.upperBound...].split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    guard fields.count >= 3, fields[0].hasPrefix("/") else { return .failure(.failed("Couldn't read \(path) on \(host).")) }

    let zmx = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
    guard zmx.hasPrefix("/") else {
      return .failure(.failed(
        "zmx isn't installed on \(host). Yatty runs remote terminals in zmx so they outlive the connection: "
          + "install it there (github.com/neurosnap/zmx) and try again."))
    }
    return .success(RemoteDirectory(path: fields[0], home: fields[1], zmx: zmx))
  }

  /// Checks a directory on `host` before it's added. With `password`, ssh's
  /// password (or passphrase) prompt is answered with it, and that login
  /// stays up as the host's shared connection; the password isn't kept.
  static func probe(
    host: String, path: String, password: String? = nil, setup: SSHSetup = .standard
  ) async -> Result<RemoteDirectory, ProbeFailure> {
    guard isValidHost(host) else { return .failure(.failed("\"\(host)\" isn't a host ssh can connect to.")) }
    let script = probeScript(path: path)
    let result: ProcessResult
    if let password {
      guard !setup.sharingOptions.isEmpty, let askpass = askpassHelper(in: setup.controlDirectory) else {
        return .failure(.failed("Yatty has nowhere to keep the connection, so a password login wouldn't last."))
      }
      let argv = [setup.executable] + setup.sharingOptions
        + ["-T", "-o", "NumberOfPasswordPrompts=1", "-o", "ConnectTimeout=10", "--", host, "exec sh -c " + CLIRules.portableQuote(script)]
      result = await setup.run(
        argv,
        env: [
          "SSH_ASKPASS": askpass, "SSH_ASKPASS_REQUIRE": "force",
          "DISPLAY": ProcessInfo.processInfo.environment["DISPLAY"] ?? ":0", "YATTY_SSH_SECRET": password,
        ],
        timeout: 30)
    } else {
      result = await setup.run(argv(host: host, command: script, tty: false, setup: setup), timeout: 30)
    }
    return parseProbe(status: result.status, stdout: result.stdout, stderr: result.stderr, host: host, path: path)
  }

  /// A command on `host`, in batch mode. A host that logs in by password is
  /// only reached over a connection that's already up: each try without one
  /// would be a failed login there, and enough of those lock the user out.
  static func run(on host: SSHHost, _ command: String, setup: SSHSetup = .standard) async -> ProcessResult? {
    if host.needsPassword, !(await isConnected(host: host.host, setup: setup)) { return nil }
    return await setup.run(argv(host: host.host, command: command, tty: false, setup: setup), timeout: 20)
  }

  /// What a remote "New Agent" session runs: claude through the login
  /// shell, then that shell. Started by zmx, never typed, so it can't land
  /// in a password prompt.
  static let agentProgram = ["sh", "-c", #""${SHELL:-/bin/sh}" -l -c claude; exec "${SHELL:-/bin/sh}" -l"#]

  /// A remote pane's terminal: ssh with a terminal, into the directory, then
  /// zmx attach (creating the session if it's new: the login shell, or
  /// `program`). TERM is one every host knows; few have xterm-ghostty's
  /// terminfo. Plain shell words for libghostty's `bash -c "exec -l …"`.
  static func attachCommand(
    host: SSHHost, directory: String, session: String, program: [String] = [], setup: SSHSetup = .standard
  ) -> String {
    let remote = "cd -- \(remotePathExpr(directory)) && ZMX_NO_DETACH_KEY=1 exec "
      + ([host.zmx, "attach", session] + program).map(shellQuote).joined(separator: " ")
    let ssh = argv(host: host.host, command: remote, tty: true, setup: setup)
    return (["/usr/bin/env", "TERM=xterm-256color"] + ssh).map(shellQuote).joined(separator: " ")
  }

  /// Whether `session` is running on `host`; nil when the host couldn't be
  /// asked.
  static func sessionExists(_ session: String, on host: SSHHost, setup: SSHSetup = .standard) async -> Bool? {
    guard let result = await run(on: host, shellQuote(host.zmx) + " list --short", setup: setup), result.ok else {
      return nil
    }
    return result.stdout.split(separator: "\n").contains { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) == session }
  }

  /// Ends sessions on `host`; false when it couldn't be reached.
  static func kill(_ sessions: [String], on host: SSHHost, setup: SSHSetup = .standard) async -> Bool {
    guard !sessions.isEmpty else { return true }
    let command = ([host.zmx, "kill"] + sessions).map(shellQuote).joined(separator: " ") + " >/dev/null 2>&1; true"
    return await run(on: host, command, setup: setup)?.ok ?? false
  }
}
