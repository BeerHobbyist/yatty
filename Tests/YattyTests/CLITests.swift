import Foundation
import Testing
import YattyProtocol

@testable import Yatty

// MARK: Arguments

private let inside = ["YATTY_WORKTREE": "/w", "YATTY_PANE": "yatty-abc-1f2e3d"]

@Test func tabNewKeepsTheCommandWhole() throws {
  let request = try CLIArguments.parse(
    ["tab", "new", "--name", "dev", "--select", "--", "npm", "run", "dev", "--worktree", "x"], env: inside)
  #expect(request.op == .tabNew)
  #expect(request.name == "dev")
  #expect(request.select)
  // After `--` it's the command's, --worktree included.
  #expect(request.command == ["npm", "run", "dev", "--worktree", "x"])
  #expect(request.worktree == "/w")
  #expect(request.pane == "yatty-abc-1f2e3d")
}

@Test func worktreeComesFromTheTerminalOrTheFlag() throws {
  #expect(try CLIArguments.parse(["tab", "list"], env: inside).worktree == "/w")
  #expect(try CLIArguments.parse(["--worktree", "/o", "tab", "list"], env: inside).worktree == "/o")
  #expect(throws: CLIArgumentError.usage("not in a Yatty terminal: pass --worktree PATH")) {
    try CLIArguments.parse(["tab", "list"], env: [:])
  }
}

@Test func tabSendTakesTextKeysAndNoEnter() throws {
  let request = try CLIArguments.parse(["tab", "send", "dev", "echo", "a b", "--key", "C-c", "--no-enter"], env: inside)
  #expect(request.tab == "dev")
  #expect(request.text == ["echo", "a b"])
  #expect(request.keys == ["C-c"])
  #expect(!request.enter)
  #expect(throws: CLIArgumentError.self) { try CLIArguments.parse(["tab", "send", "dev"], env: inside) }
}

@Test func argumentMistakesAreUsageErrors() {
  for args in [
    ["tab", "rename", "dev"], ["tab", "read", "dev", "--lines", "0"], ["tab", "read"], ["tab", "close"],
    ["tab", "new", "--name"], ["tab", "new", "npm"], ["notify"], ["notify", "--title", "T"], ["frob"], ["tab"],
    ["diff", "a", "b"],
  ] {
    #expect(throws: CLIArgumentError.self, "\(args)") { try CLIArguments.parse(args, env: inside) }
  }
}

@Test func notifyAndDiffDefaults() throws {
  let notify = try CLIArguments.parse(["notify", "tests", "pass", "--title", "CI"], env: inside)
  #expect(notify.text == ["tests", "pass"])
  #expect(notify.title == "CI")
  #expect(try CLIArguments.parse(["diff"], env: inside).target == "working")
  #expect(try CLIArguments.parse(["tab", "rename", "2", "dev", "server"], env: inside).name == "dev server")
}

@Test func requestsSurviveTheWire() throws {
  var request = CLIRequest(op: .tabSend)
  request.worktree = "/w/with space"
  request.tab = "it's"
  request.text = ["echo \"a  b\"", "line\nbreak", "$(rm -rf ~)", "tab\there", "ünïcödé 🙂"]
  request.keys = ["C-c"]
  let decoded = try JSONDecoder().decode(CLIRequest.self, from: JSONEncoder().encode(request))
  #expect(decoded == request)
}

// MARK: Sandbox rules

@Test func sandboxStartsNothingWithoutItsCommand() {
  for op in [CLIRequest.Op.tabNew, .diff] {
    let request = CLIRequest(op: op)
    #expect(CLIRules.refusal(request, sandboxed: true, sandboxCommand: nil, targetSandboxed: false) != nil)
    #expect(CLIRules.refusal(request, sandboxed: true, sandboxCommand: "  ", targetSandboxed: false) != nil)
    #expect(CLIRules.refusal(request, sandboxed: true, sandboxCommand: "fence --", targetSandboxed: false) == nil)
    #expect(CLIRules.refusal(request, sandboxed: false, sandboxCommand: nil, targetSandboxed: false) == nil)
  }
}

@Test func sandboxTypesOnlyIntoItsOwnPanes() {
  let send = CLIRequest(op: .tabSend)
  #expect(CLIRules.refusal(send, sandboxed: true, sandboxCommand: "fence --", targetSandboxed: false) != nil)
  #expect(CLIRules.refusal(send, sandboxed: true, sandboxCommand: "fence --", targetSandboxed: true) == nil)
  #expect(CLIRules.refusal(send, sandboxed: false, sandboxCommand: nil, targetSandboxed: false) == nil)
  for op in [CLIRequest.Op.tabList, .tabRead, .tabSelect, .tabRename, .tabClose, .notify, .status] {
    #expect(CLIRules.refusal(CLIRequest(op: op), sandboxed: true, sandboxCommand: nil, targetSandboxed: false) == nil)
  }
}

/// The prefix runs the program with its arguments untouched, and `cwd` is
/// entered inside the sandbox, not by the app.
@Test func sandboxArgvPassesArgumentsThrough() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yatty-argv-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  let program = ["/bin/sh", "-c", #"pwd -P; printf '<%s>' "$@""#, "sh", "a b", "it's", "$(echo no)", "*"]
  let argv = CLIRules.sandboxArgv(prefix: "env SANDBOXED=1", program: program, cwd: dir.path)
  let result = Run.runSync(argv[0], Array(argv.dropFirst()), cwd: "/")
  #expect(result.ok)
  #expect(result.stdout == canonicalPath(dir.path) + "\n<a b><it's><$(echo no)><*>")
  #expect(argv.prefix(3) == ["/bin/sh", "-c", #"exec env SANDBOXED=1 "$@""#])
}

@Test func sandboxedPanesStayMarked() throws {
  var layout = WorktreeLayout.initial
  layout.addTab(pane: "a1", id: "ta", select: false)
  layout.sandboxed.insert("a1")
  // In the background: the user's tab stays selected.
  #expect(layout.selectedTab == "t0")
  let decoded = try JSONDecoder().decode(WorktreeLayout.self, from: JSONEncoder().encode(layout))
  #expect(decoded.sandboxed == ["a1"])
  layout.close("a1")
  #expect(layout.sandboxed.isEmpty)
  // A layout stored before sandboxes existed.
  let old = #"{"tabs":[{"id":"t0","root":{"pane":{"_0":"0"}},"focusedPane":"0"}],"selectedTab":"t0"}"#
  let legacy = try JSONDecoder().decode(WorktreeLayout.self, from: Data(old.utf8))
  #expect(legacy.sandboxed.isEmpty)
}

// MARK: Tabs

@Test func tabsByNumberThenName() {
  let titles = ["zsh", "dev", "2"]
  #expect(CLIRules.tabIndex("1", titles: titles) == 0)
  #expect(CLIRules.tabIndex("dev", titles: titles) == 1)
  // A number names a position; one past the end can still be a name.
  #expect(CLIRules.tabIndex("2", titles: titles) == 1)
  #expect(CLIRules.tabIndex("4", titles: titles) == nil)
  #expect(CLIRules.tabIndex("+1", titles: titles) == nil)
  #expect(CLIRules.tabIndex("nope", titles: titles) == nil)
  #expect(CLIRules.noTab("x", titles: titles) == #"no tab "x"; tabs: 1:zsh, 2:dev, 3:2"#)
}

@Test func burstOfSameNamedTabsMakesOne() {
  var titles = ["zsh"]
  var made = 0
  for _ in 0..<2 where CLIRules.nameClash("dev", titles: titles) == nil {
    titles.append("dev")
    made += 1
  }
  #expect(made == 1)
  #expect(CLIRules.nameClash(nil, titles: titles) == nil)
}

@Test func oneWordCommandIsTypedAsIs() {
  #expect(CLIRules.commandLine([]) == nil)
  #expect(CLIRules.commandLine(["npm run dev 2>&1 | tee log"]) == "npm run dev 2>&1 | tee log")
  #expect(CLIRules.commandLine(["echo", "a b", "it's"]) == #"'echo' 'a b' 'it'\''s'"#)
}

@Test func lastLinesDropTheBlankScreen() {
  #expect(CLIRules.lastLines("a\nb\r\nc\n\n   \n", count: 2) == "b\nc")
  #expect(CLIRules.lastLines("a\nb", count: 50) == "a\nb")
  #expect(CLIRules.lastLines("", count: 5) == "")
}

@Test func keysAsTerminalBytes() {
  #expect(CLIRules.keyBytes("C-c") == "\u{03}")
  #expect(CLIRules.keyBytes("C-d") == "\u{04}")
  #expect(CLIRules.keyBytes("Enter") == "\r")
  #expect(CLIRules.keyBytes("Escape") == "\u{1b}")
  #expect(CLIRules.keyBytes("Up") == "\u{1b}[A")
  #expect(CLIRules.keyBytes("M-x") == "\u{1b}x")
  #expect(CLIRules.keyBytes("M-Enter") == "\u{1b}\r")
  #expect(CLIRules.keyBytes("y") == "y")
  #expect(CLIRules.keyBytes("C-é") == nil)
  #expect(CLIRules.keyBytes("Hyper-x") == nil)
  #expect(CLIRules.keyBytes("Bogus") == nil)
}

@Test func sendTypesTextThenEnterThenKeys() throws {
  var request = CLIRequest(op: .tabSend)
  request.text = ["echo", "hi"]
  request.keys = ["C-c"]
  #expect(try CLIRules.input(request).get() == "echo hi\r\u{03}")
  request.enter = false
  #expect(try CLIRules.input(request).get() == "echo hi\u{03}")
  request.keys = ["Nope"]
  #expect(throws: CLIError.self) { try CLIRules.input(request).get() }
}

@Test func sendKeepsInputInOneArgument() {
  let input = "echo \"a  b\" -- --force\r"
  #expect(Zmx.sendArguments(session: "yatty-1", input: input) == ["send", "yatty-1", input])
}

@Test func diffRefsCantBeOptions() throws {
  #expect(try CLIRules.diffTarget("working", base: "").get() == .working)
  #expect(try CLIRules.diffTarget("base", base: "origin/main").get() == .base("origin/main"))
  #expect(throws: CLIError.self) { try CLIRules.diffTarget("base", base: "HEAD").get() }
  #expect(throws: CLIError.self) { try CLIRules.diffTarget("--output=/tmp/x", base: "").get() }
  #expect(try CLIRules.diffTarget("main~2..HEAD", base: "").get() == .ref("main~2..HEAD"))
}

// MARK: Hooks

@Test func sessionStartTellsAgentsAboutTheCLI() throws {
  let hooks = try #require(AgentHooks.settings()["hooks"] as? [String: [[String: Any]]])
  let start = try #require(hooks["SessionStart"]?.first?["hooks"] as? [[String: Any]])
  let commands = start.compactMap { $0["command"] as? String }
  #expect(commands.count == 2)
  let note = try #require(commands.last)
  // Recognised as Yatty's, so "Track every claude" takes it out again.
  #expect(note.contains("YATTY_AGENT_DIR"))
  let silent = Run.runSync("/bin/sh", ["-c", note], env: ["YATTY_AGENT_DIR": "", "YATTY_CLI": ""])
  #expect(silent.ok && silent.stdout.isEmpty)
  let told = Run.runSync("/bin/sh", ["-c", note], env: ["YATTY_AGENT_DIR": "/a", "YATTY_CLI": "/b/yatty"])
  #expect(told.ok && told.stdout == AgentHooks.note + "\n")
}

// MARK: Connecting

@Test func failedConnectionsSaySo() {
  #expect(CLIClient.connectFailure(errno: ENOENT, path: "/s").hasPrefix("Yatty isn't running"))
  #expect(CLIClient.connectFailure(errno: ECONNREFUSED, path: "/s").hasPrefix("Yatty isn't running"))
  #expect(CLIClient.connectFailure(errno: EPERM, path: "/s").contains("allowUnixSockets"))
}

@Test func noAppFailsFast() {
  let started = Date()
  #expect(throws: CLIClientError.self) {
    try CLIClient.send(CLIRequest(op: .tabList), to: "/tmp/yatty-nobody-\(getpid()).sock")
  }
  #expect(Date().timeIntervalSince(started) < 1)
}

/// The app's sockets, end to end: each says which one a request came in on,
/// and a request arrives exactly as sent. Bound at fixed paths so a sandbox
/// running the tests can be told exactly which to allow.
@Test func serverAnswersEachSocket() async throws {
  let dir = "/private/tmp/yatty-test-\(getuid())"
  let handler: CLIServer.Handler = { request, sandboxed in
    CLIResponse(ok: true, output: (sandboxed ? "sandbox:" : "app:") + request.text.joined(separator: "|"))
  }
  let app = try #require(CLIServer(path: dir + "/app.sock", sandboxed: false, handler: handler))
  let sandbox = try #require(CLIServer(path: dir + "/sandbox.sock", sandboxed: true, handler: handler))
  defer {
    app.stop()
    sandbox.stop()
  }
  // A second Yatty doesn't take a live socket over.
  #expect(CLIServer(path: dir + "/app.sock", sandboxed: true, handler: handler) == nil)

  let request = {
    var request = CLIRequest(op: .tabSend)
    request.text = ["a b", "it's\n", String(repeating: "x", count: 200_000)]
    return request
  }()
  let viaApp = try await Task.detached { try CLIClient.send(request, to: dir + "/app.sock") }.value
  #expect(viaApp.output == "app:" + request.text.joined(separator: "|"))
  let viaSandbox = try await Task.detached { try CLIClient.send(request, to: dir + "/sandbox.sock") }.value
  #expect(viaSandbox.output.hasPrefix("sandbox:"))
  #expect((try FileManager.default.attributesOfItem(atPath: dir + "/app.sock")[.posixPermissions] as? Int) == 0o600)
}

// MARK: Verifier findings

@Test func negativeLineCountsCantCrash() {
  #expect(CLIRules.lastLines("a\nb", count: -1) == "")
  #expect(CLIRules.lastLines("a\nb", count: 0) == "")
}

/// `tab new -- WORDS` is typed into the user's login shell: each word must
/// come out as itself in every shell Yatty may find there.
@Test func typedWordsMeanThemselvesInEveryShell() throws {
  let words = [#"a\b"#, #"tail\"#, "it's", "$HOME", "*", "", "x\ny", #"\'"#, "ünï 🙂"]
  let line = try #require(CLIRules.commandLine(["printf", "[%s]"] + words))
  let expected = words.map { "[\($0)]" }.joined()
  let shells = ["/bin/sh", "/bin/bash", "/bin/zsh", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
    .filter { FileManager.default.isExecutableFile(atPath: $0) }
  #expect(shells.count >= 3)
  for shell in shells {
    let result = Run.runSync(shell, ["-c", line])
    #expect(result.stdout == expected, "\(shell): \(result.stdout) \(result.stderr)")
  }
}

@Test func tabNamesArentBlankOrNumbers() throws {
  #expect(CLIRules.badName("  ") != nil)
  #expect(CLIRules.badName("3") != nil)
  #expect(CLIRules.badName("dev") == nil)
  #expect(CLIRules.badName("v2") == nil)
  #expect(throws: CLIArgumentError.self) { try CLIArguments.parse(["tab", "new", "--name", "  "], env: inside) }
}

@Test func cliTabsGoLastSoTheirNumbersHold() {
  var layout = WorktreeLayout.initial
  layout.addTab(pane: "a", id: "ta", select: false, atEnd: true)
  layout.addTab(pane: "b", id: "tb", select: false, atEnd: true)
  #expect(layout.tabs.map(\.id) == ["t0", "ta", "tb"])
}

@Test func statusNeedsNoWorktree() throws {
  #expect(try CLIArguments.parse(["status"], env: [:]).op == .status)
}

/// Idle clients filling one socket get a quick "busy" there and never slow
/// the other one.
@Test func idleFloodStaysOnItsSocket() async throws {
  let dir = "/private/tmp/yatty-test-\(getuid())/flood"
  let handler: CLIServer.Handler = { _, sandboxed in CLIResponse(ok: true, output: sandboxed ? "sandbox" : "app") }
  let app = try #require(CLIServer(path: dir + "/app.sock", sandboxed: false, handler: handler))
  let sandbox = try #require(CLIServer(path: dir + "/sandbox.sock", sandboxed: true, handler: handler))
  defer {
    app.stop()
    sandbox.stop()
  }
  var idle: [Int32] = []
  for _ in 0..<CLIServer.maxConnections {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = try #require(CLIServer.address(dir + "/sandbox.sock"))
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    #expect(connected == 0)
    idle.append(fd)
  }
  defer { idle.forEach { close($0) } }
  try await Task.sleep(for: .milliseconds(200))

  let started = Date()
  let busy = try await Task.detached { try CLIClient.send(CLIRequest(op: .status), to: dir + "/sandbox.sock") }.value
  #expect(busy.error == "Yatty is busy: try again")
  // Hung up on mid-request, the CLI still shows why.
  let big = {
    var request = CLIRequest(op: .tabSend)
    request.text = [String(repeating: "x", count: 600_000)]
    return request
  }()
  let busyBig = try await Task.detached { try CLIClient.send(big, to: dir + "/sandbox.sock") }.value
  #expect(busyBig.error == "Yatty is busy: try again")
  let other = try await Task.detached { try CLIClient.send(CLIRequest(op: .status), to: dir + "/app.sock") }.value
  #expect(other.output == "app")
  #expect(Date().timeIntervalSince(started) < 1)
}
