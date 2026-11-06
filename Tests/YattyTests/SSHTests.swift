import Foundation
import Testing

@testable import Yatty

/// A fake ssh whose hosts are directories here (Tests/fixtures/fake-ssh),
/// each with its own home, PATH, shell and maybe a password.
private struct FakeHosts {
  let root: URL
  let setup: SSHSetup

  init() throws {
    // Short: the shared-connection directory must fit a socket path.
    root = URL(fileURLWithPath: "/private/tmp/yatty-ssh-test-\(getuid())-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let control = root.appendingPathComponent("c").path
    try FileManager.default.createDirectory(atPath: control, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let fake = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("fixtures/fake-ssh").path
    setup = SSHSetup(executable: fake, controlDirectory: control, environment: ["FAKE_SSH_ROOT": root.path])
  }

  /// A host with a home, and zmx on its PATH unless told otherwise.
  @discardableResult
  func host(_ name: String, zmx: Bool = true, password: String? = nil, loginShell: String? = nil) throws -> URL {
    let dir = root.appendingPathComponent(name)
    let fm = FileManager.default
    try fm.createDirectory(at: dir.appendingPathComponent("home"), withIntermediateDirectories: true)
    try fm.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
    if zmx {
      // Logs what it's asked to do, and where.
      let script = "#!/bin/sh\nprintf '%s|' \"$(pwd -P)\" \"$TERM\" \"$@\" >>\"\(dir.path)/zmx.log\"\necho >>\"\(dir.path)/zmx.log\"\n"
      try write(script, to: dir.appendingPathComponent("bin/zmx"), executable: true)
    }
    if let password { try write(password, to: dir.appendingPathComponent("password")) }
    if let loginShell { try write(loginShell, to: dir.appendingPathComponent("shell"), executable: true) }
    return dir
  }

  func logins(_ name: String) -> Int {
    ((try? String(contentsOf: root.appendingPathComponent("\(name)/log"), encoding: .utf8)) ?? "")
      .split(separator: "\n").count
  }

  func zmxLog(_ name: String) -> [String] {
    ((try? String(contentsOf: root.appendingPathComponent("\(name)/zmx.log"), encoding: .utf8)) ?? "")
      .split(separator: "\n").map(String.init)
  }

  func write(_ text: String, to url: URL, executable: Bool = false) throws {
    try text.write(to: url, atomically: true, encoding: .utf8)
    if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

// MARK: Pure rules

@Test func hostsCantBeOptions() {
  for good in ["box", "me@box", "ssh://me@box:2222", "box.example.com"] { #expect(SSH.isValidHost(good), "\(good)") }
  for bad in ["", "-oProxyCommand=touch /tmp/x", "box -o x", "a\nb", " box"] { #expect(!SSH.isValidHost(bad), "\(bad)") }
}

@Test func remotePathsStayOneWord() {
  #expect(SSH.remotePathExpr("~") == #""$HOME""#)
  #expect(SSH.remotePathExpr("~/a b") == #""$HOME"/'a b'"#)
  #expect(SSH.remotePathExpr("/srv/it's") == #"'/srv/it'\''s'"#)
  #expect(SSH.remotePathExpr("~user/x") == #"'~user/x'"#)
}

@Test func pathsShownUnderHome() {
  #expect(SSH.displayPath("/home/me", home: "/home/me") == "~")
  #expect(SSH.displayPath("/home/me/src/app", home: "/home/me") == "~/src/app")
  #expect(SSH.displayPath("/home/meow", home: "/home/me") == "/home/meow")
  #expect(SSH.displayPath("/srv", home: "/") == "/srv")
}

@Test func configHostsSkipPatterns() {
  let config = """
    Host work box
      HostName 10.0.0.2
    Host *
      ForwardAgent no
    host pi # the one on the shelf
    Host !bastion gate?
    Match host foo
    """
  #expect(SSH.parseConfigHosts(config) == ["work", "box", "pi"])
}

@Test func batchAndTerminalArgv() {
  let setup = SSHSetup(executable: "/usr/bin/ssh", controlDirectory: "/c")
  let batch = SSH.argv(host: "box", command: "echo 'hi'", tty: false, setup: setup)
  #expect(batch.contains("BatchMode=yes"))
  #expect(batch.contains("ControlPath=/c/%C"))
  #expect(Array(batch.suffix(3)) == ["--", "box", #"exec sh -c 'echo '\''hi'\'"#])
  let tty = SSH.argv(host: "box", command: "x", tty: true, setup: SSHSetup())
  #expect(tty.contains("-t") && !tty.contains("BatchMode=yes") && !tty.contains("ControlMaster=auto"))
}

@Test func controlDirectoryMustFitAndBePrivate() throws {
  let base = "/private/tmp/yatty-ctl-\(getuid())-\(UUID().uuidString.prefix(6))"
  defer { try? FileManager.default.removeItem(atPath: base) }
  let open = base + "/open"
  try FileManager.default.createDirectory(atPath: open, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
  // ssh binds `<dir>/<40 hex>.<16 random>` first: 45 bytes of directory fit, 46 don't.
  let fits = base + "/" + String(repeating: "f", count: 45 - base.utf8.count - 1)
  let tooLong = base + "/" + String(repeating: "t", count: 46 - base.utf8.count - 1)
  #expect(fits.utf8.count == 45 && tooLong.utf8.count == 46)
  #expect(SSH.controlDirectory(candidates: [tooLong, open, fits]) == fits)
  #expect(SSH.controlDirectory(candidates: [tooLong]) == nil)
}

@Test func askpassAnswersOnlyPasswords() throws {
  let dir = "/private/tmp/yatty-askpass-\(getuid())-\(UUID().uuidString.prefix(6))"
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(atPath: dir) }
  let helper = try #require(SSH.askpassHelper(in: dir))
  let env = ["YATTY_SSH_SECRET": "s3cret pass"]
  for prompt in [
    "me@box's password: ", "Enter passphrase for key '/Users/me/.ssh/id_ed25519': ", "Password:", "(me@box) Password: ",
    "Enter passphrase for key '/x/assword_key': ",
  ] {
    let result = Run.runSync(helper, [prompt], env: env)
    #expect(result.ok && result.stdout == "s3cret pass\n", "\(prompt)")
  }
  for prompt in [
    "Are you sure you want to continue connecting (yes/no/[fingerprint])? ", "Verification code: ",
    "One-time password (OATH) for me: ",
    "The authenticity of host 'password-box (10.0.0.9)' can't be established.\nAre you sure you want to continue connecting (yes/no)? ",
  ] {
    let result = Run.runSync(helper, [prompt], env: env)
    #expect(!result.ok && result.stdout.isEmpty, "\(prompt)")
  }
  #expect(!SSH.askpassScript.contains("s3cret"))
}

@Test func probeErrorsSayWhy() {
  #expect(SSH.parseProbe(status: 3, stdout: "", stderr: "", host: "box", path: "~/x") == .failure(.failed("~/x doesn't exist on box, or isn't a directory.")))
  if case .failure(.needsPassword) = SSH.parseProbe(
    status: 255, stdout: "", stderr: "me@box: Permission denied (publickey,password).", host: "box", path: "~")
  {} else { Issue.record("Permission denied should ask for a password") }
  if case .failure(.failed(let message)) = SSH.parseProbe(
    status: 255, stdout: "", stderr: "Host key verification failed.", host: "box", path: "~")
  {
    #expect(message.contains("ssh box"))
  } else { Issue.record("a host key failure should say how to accept it") }
}

// MARK: Through the fake ssh

@Test func probeResolvesOddPaths() async throws {
  let hosts = try FakeHosts()
  defer { hosts.remove() }
  let box = try hosts.host("box")
  let odd = "we ird;$x 'q'"
  try FileManager.default.createDirectory(at: box.appendingPathComponent("home/\(odd)"), withIntermediateDirectories: true)
  let newline = "new\nline"
  try FileManager.default.createDirectory(at: box.appendingPathComponent("home/\(newline)"), withIntermediateDirectories: true)
  #expect(try await SSH.probe(host: "box", path: "~/\(newline)", setup: hosts.setup).get().path.hasSuffix("/" + newline))
  let found = try await SSH.probe(host: "box", path: "~/\(odd)", setup: hosts.setup).get()
  let home = box.appendingPathComponent("home").path
  #expect(found == RemoteDirectory(path: home + "/" + odd, home: home, zmx: box.appendingPathComponent("bin/zmx").path))
  #expect(await SSH.probe(host: "box", path: "~/nope", setup: hosts.setup) == .failure(.failed("~/nope doesn't exist on box, or isn't a directory.")))
}

/// zmx often isn't on a non-interactive ssh's PATH; the login shell finds it.
@Test func probeFindsZmxThroughTheLoginShell() async throws {
  let hosts = try FakeHosts()
  defer { hosts.remove() }
  try hosts.host("box", zmx: false, loginShell: "#!/bin/sh\necho motd-noise\necho /opt/zmx/bin/zmx\n")
  #expect(try await SSH.probe(host: "box", path: "~", setup: hosts.setup).get().zmx == "/opt/zmx/bin/zmx")
  try hosts.host("bare", zmx: false, loginShell: "#!/bin/sh\nexit 1\n")
  guard case .failure(.failed(let message)) = await SSH.probe(host: "bare", path: "~", setup: hosts.setup) else {
    Issue.record("no zmx should fail")
    return
  }
  #expect(message.contains("zmx isn't installed on bare"))
}

@Test func passwordHostsLogInOnceAndNeverInTheBackground() async throws {
  let hosts = try FakeHosts()
  defer { hosts.remove() }
  try hosts.host("pw", password: "open sesame")
  if case .failure(.needsPassword) = await SSH.probe(host: "pw", path: "~", setup: hosts.setup) {} else {
    Issue.record("a password host should ask for one")
  }
  if case .failure(.needsPassword) = await SSH.probe(host: "pw", path: "~", password: "wrong", setup: hosts.setup) {} else {
    Issue.record("a wrong password should ask again")
  }
  let host = SSHHost(host: "pw", home: "", zmx: "zmx", needsPassword: true, directories: [])
  let before = hosts.logins("pw")
  // Not connected: a background call doesn't even try.
  #expect(await SSH.run(on: host, "true", setup: hosts.setup) == nil)
  #expect(!(await SSH.kill(["s"], on: host, setup: hosts.setup)))
  #expect(hosts.logins("pw") == before)

  _ = try await SSH.probe(host: "pw", path: "~", password: "open sesame", setup: hosts.setup).get()
  #expect(await SSH.isConnected(host: "pw", setup: hosts.setup))
  let after = hosts.logins("pw")
  #expect(await SSH.run(on: host, "true", setup: hosts.setup)?.ok == true)
  #expect(hosts.logins("pw") == after)
}

/// After a pane's ssh ends, the host says whether its session lives on.
@Test func sessionCheckTellsGoneFromUnreachable() async throws {
  let hosts = try FakeHosts()
  defer { hosts.remove() }
  let box = try hosts.host("box", zmx: false)
  try hosts.write("#!/bin/sh\n[ \"$1\" = list ] && printf 'yatty-1\\tpid=1\\nyatty-2\\n'\n", to: box.appendingPathComponent("bin/zmx"), executable: true)
  let host = SSHHost(host: "box", home: "", zmx: box.appendingPathComponent("bin/zmx").path)
  #expect(await SSH.sessionExists("yatty-1", on: host, setup: hosts.setup) == true)
  #expect(await SSH.sessionExists("yatty-3", on: host, setup: hosts.setup) == false)
  let unreachable = SSHHost(host: "nowhere", home: "", zmx: "zmx")
  #expect(await SSH.sessionExists("yatty-1", on: unreachable, setup: hosts.setup) == nil)
}

@Test func killEndsExactlyThoseSessions() async throws {
  let hosts = try FakeHosts()
  defer { hosts.remove() }
  let box = try hosts.host("box")
  let host = SSHHost(host: "box", home: "", zmx: box.appendingPathComponent("bin/zmx").path, directories: [])
  #expect(await SSH.kill(["yatty-1", "yatty-1-a b"], on: host, setup: hosts.setup))
  #expect(hosts.zmxLog("box").map { $0.split(separator: "|").dropFirst(2).joined(separator: "|") } == ["kill|yatty-1|yatty-1-a b"])
}

/// The terminal's command, run as libghostty would: into the directory,
/// then zmx attach with the session's name, each one word.
@Test func attachRunsZmxInTheDirectory() async throws {
  let hosts = try FakeHosts()
  defer { hosts.remove() }
  let box = try hosts.host("box")
  let odd = box.appendingPathComponent("home/a b 'c'")
  try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
  let host = SSHHost(host: "box", home: "", zmx: box.appendingPathComponent("bin/zmx").path, directories: [odd.path])
  let command = SSH.attachCommand(host: host, directory: odd.path, session: "yatty-0a1b", setup: hosts.setup)
  var env = hosts.setup.environment
  env["TERM"] = "xterm-ghostty"
  let result = Run.runSync("/bin/bash", ["-c", "exec -l \(command)"], env: env)
  #expect(result.ok, "\(result.stderr)")
  // A TERM every host knows, not Ghostty's own.
  #expect(hosts.zmxLog("box") == ["\(canonicalPath(odd.path))|xterm-256color|attach|yatty-0a1b|"])

  // A "New Agent" session starts claude itself: nothing is typed.
  let agent = SSH.attachCommand(
    host: host, directory: odd.path, session: "yatty-0a1b-c", program: SSH.agentProgram, setup: hosts.setup)
  _ = Run.runSync("/bin/bash", ["-c", "exec -l \(agent)"], env: env)
  #expect(hosts.zmxLog("box").last == "\(canonicalPath(odd.path))|xterm-256color|attach|yatty-0a1b-c|" + SSH.agentProgram.joined(separator: "|") + "|")
}

@Test func hostsAndRemoteWorktreesPersist() throws {
  var state = StoredState()
  state.hosts = [SSHHost(host: "box", home: "/home/me", zmx: "/usr/bin/zmx", needsPassword: true, directories: ["/home/me/app"])]
  let decoded = try JSONDecoder().decode(StoredState.self, from: JSONEncoder().encode(state))
  #expect(decoded.hosts == state.hosts)
  let worktree = try #require(decoded.hosts.first?.worktrees.first)
  #expect(worktree.id == "ssh:box:/home/me/app")
  // Two names for one machine never share a session.
  #expect(worktree.sessionKey == worktree.id)
  #expect(Worktree(path: "/x", branch: nil, head: nil, isMain: false).sessionKey == "/x")
  #expect(worktree.isRemote && worktree.exists)
  // A state file from before hosts existed.
  let old = try JSONDecoder().decode(StoredState.self, from: Data(#"{"repos":[]}"#.utf8))
  #expect(old.hosts.isEmpty && old.remoteCleanup.isEmpty)
}

/// sshd runs the command through the remote login shell, whichever it is.
@Test func remoteCommandMeansTheSameInEveryLoginShell() {
  let command = #"printf '[%s]' 'a\b' "it's" '$HOME' 'x\\y'"#
  let word = SSH.argv(host: "box", command: command, tty: false, setup: SSHSetup()).last!
  let shells = ["/bin/sh", "/bin/bash", "/bin/zsh", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
    .filter { FileManager.default.isExecutableFile(atPath: $0) }
  for shell in shells {
    let result = Run.runSync(shell, ["-c", word])
    #expect(result.stdout == #"[a\b][it's][$HOME][x\\y]"#, "\(shell): \(result.stdout) \(result.stderr)")
  }
}
