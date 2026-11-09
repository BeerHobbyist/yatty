import Foundation
import Testing

@testable import Yatty

@Test func aTabSavedBeforeTheCodeViewStillLoads() throws {
  let old = #"{"id":"t1","root":{"pane":{"_0":"0"}},"focusedPane":"0"}"#
  let tab = try JSONDecoder().decode(TerminalTab.self, from: Data(old.utf8))
  #expect(tab.code == nil)
  // A code view saved with only some of its fields keeps the defaults.
  let code = try JSONDecoder().decode(CodeView.self, from: Data(#"{"file":"a.swift"}"#.utf8))
  #expect(code == CodeView(file: "a.swift"))
  #expect(code.shown && code.following && code.base == .head && code.comments.isEmpty)
  let comment = try JSONDecoder().decode(
    DiffComment.self, from: Data(#"{"id":"c","path":"p","line":1,"side":"new","code":"","text":"t"}"#.utf8))
  #expect(!comment.sent)
}

@Test func theCodeViewIsKeptPerTab() throws {
  var layout = WorktreeLayout.initial
  let tabID = layout.tabs[0].id
  layout.updateCode(tabID) { $0.file = "Sources/App.swift" }
  #expect(layout.tabs[0].code?.file == "Sources/App.swift")
  #expect(layout.tabs[0].code?.shown == true)
  layout.updateCode(tabID) { $0.shown = false }
  let decoded = try JSONDecoder().decode(WorktreeLayout.self, from: JSONEncoder().encode(layout))
  #expect(decoded.tabs[0].code == CodeView(shown: false, file: "Sources/App.swift"))
  // A diff tab has no code beside it.
  layout.addDiffTab(pane: "d1", id: "td", target: .working)
  layout.updateCode("td") { $0.file = "x" }
  #expect(layout.tabs.last?.code == nil)
}

@Test func definitionsAreFoundAcrossLanguages() {
  let name = "refresh"
  #expect(CodeDefinitions.isName(name) && CodeDefinitions.isName("$state") && CodeDefinitions.isName("_x1"))
  #expect(!CodeDefinitions.isName("a b") && !CodeDefinitions.isName("1x") && !CodeDefinitions.isName("") && !CodeDefinitions.isName("-e"))
  // What `git grep -n -z` prints: path NUL line NUL text.
  let lines = [
    ("Sources/Auth/Refresher.swift", 7, "  func refresh(_ session: Session) async throws -> Session {"),
    ("Sources/Auth/Session.swift", 12, "    try await refresher.refresh(self)"),
    ("lib/auth.dart", 20, "  Future<Session> refresh(Session old) async {"),
    ("lib/auth.dart", 31, "    return refresh(old);"),
    ("web/auth.ts", 4, "export async function refresh(session: Session) {"),
    ("web/auth.ts", 9, "  const refreshed = await refresh(s)"),
    ("web/client.ts", 3, "  refresh() {"),
    ("go/auth.go", 11, "func (r *Refresher) refresh(s Session) Session {"),
    ("py/auth.py", 2, "def refresh(session):"),
    ("Sources/Auth/Session.swift", 30, "  var refreshes = 0"),
  ]
  let output = lines.map { "\($0.0)\0\($0.1)\0\($0.2)\n" }.joined()
  let hits = CodeDefinitions.hits(output, name: name, from: "Sources/Auth/Session.swift")
  #expect(hits.map(\.path).contains("Sources/Auth/Refresher.swift"))
  #expect(!hits.contains { $0.text.contains("refresher.refresh(self)") }, "a call isn't a definition")
  #expect(!hits.contains { $0.text.contains("return refresh") })
  #expect(!hits.contains { $0.text.contains("await refresh(s)") })
  #expect(!hits.contains { $0.text.contains("refreshes") })
  for path in ["lib/auth.dart", "web/auth.ts", "go/auth.go", "py/auth.py", "web/client.ts"] {
    #expect(hits.contains { $0.path == path }, "\(path)")
  }
  // Declarations with a keyword come before a bare method, and a hit in
  // the file being read before the same kind elsewhere.
  #expect(hits.last?.path == "web/client.ts")
  let swift = CodeDefinitions.hits(
    "a.swift\u{0}3\u{0}struct Session {\nSources/Auth/Session.swift\u{0}3\u{0}struct Session {\n", name: "Session",
    from: "Sources/Auth/Session.swift")
  #expect(swift.map(\.path) == ["Sources/Auth/Session.swift", "a.swift"])
}

@Test func quickOpenRanksByTheFileName() {
  let files = [
    "Tests/SessionTests.swift", "Sources/Auth/Session.swift", "Sources/App.swift", "docs/sessions/notes.md",
    "Sources/Auth/Refresher.swift",
  ]
  #expect(QuickOpen.rank("session", files).prefix(2) == ["Sources/Auth/Session.swift", "Tests/SessionTests.swift"])
  #expect(QuickOpen.rank("sessT", files).first == "Tests/SessionTests.swift")
  #expect(QuickOpen.rank("auth/ref", files) == ["Sources/Auth/Refresher.swift"])
  #expect(QuickOpen.rank("xyz", files).isEmpty)
  #expect(QuickOpen.rank("", files) == files)
  #expect(QuickOpen.rank("", files, limit: 2).count == 2)
}

@Test func changedFilesComeFromGit() {
  // `git diff --name-status -z` and untracked files.
  let status = "M\0Sources/App.swift\0R087\0old name.swift\0new name.swift\0D\0gone.swift\0A\0added.swift\0"
  let changed = CodeChanges.parse(nameStatus: status, untracked: "new.txt\0")
  #expect(changed == [
    .init(path: "Sources/App.swift", status: "M"), .init(path: "new name.swift", status: "R"),
    .init(path: "gone.swift", status: "D"), .init(path: "added.swift", status: "A"), .init(path: "new.txt", status: "A"),
  ])
  #expect(CodeChanges.parse(nameStatus: "", untracked: "").isEmpty)
}

@Test func commentsReachTheAgentAsOnePaste() {
  let input = AgentInput.paste("Line one\nLine two \u{1b}[201~ rm -rf\u{7}")
  // A bracketed paste the comments can't break out of, then Enter.
  #expect(input.text == "\u{1b}[200~Line one\nLine two [201~ rm -rf\u{1b}[201~")
  #expect(input.submit == "\r")
}

@Test func theCodeViewsPromptSaysWhereItsFrom() {
  let comment = DiffComment(id: "1", path: "a.swift", line: 3, side: .new, code: "x", text: "Why?")
  #expect(LocalReviewPrompt.make(target: .working, branch: nil, comments: [comment], view: "code view")
    .contains("made in Yatty's code view"))
}

@Test func onlyChangesInTheWorktreeAreFollowed() {
  let root = "/r/wt"
  #expect(CodeWatch.relative(["/r/wt/Sources/A.swift", "/r/wt/.git/index", "/r/other/x", "/r/wt/a/.git/HEAD", "/r/wt"], in: root)
    == ["Sources/A.swift"])
  // Another worktree inside this one (the main checkout's .worktrees/) is its own.
  #expect(CodeWatch.relative(["/r/wt/.worktrees/login/A.swift", "/r/wt/B.swift"], in: root, excluding: [".worktrees/login"])
    == ["B.swift"])
}

@Test func codeFilesAreReadAsText() async throws {
  let repo = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yatty-code-\(UUID().uuidString)").path
  defer { try? FileManager.default.removeItem(atPath: repo) }
  func git(_ args: String...) async { _ = await Run.run("/usr/bin/env", ["git", "-C", repo] + args) }
  _ = await Run.run("/usr/bin/env", ["git", "init", "-q", repo])
  try "one\ntwo\nthree\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
  await git("add", ".")
  await git("-c", "user.name=y", "-c", "user.email=y@y", "commit", "-qm", "init")
  await git("config", "diff.noprefix", "true")
  try "one\n2\nthree\nfour\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
  try "new\n".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)
  try Data([0x89, 0x50, 0x00, 0x01]).write(to: URL(fileURLWithPath: repo + "/bin.png"))

  let changed = try await CodeSource.load("a.txt", in: repo, against: "HEAD")
  #expect(changed.text == "one\n2\nthree\nfour\n")
  #expect(changed.diff.contains("--- a/a.txt") && changed.diff.contains("-two\n+2\n") && !changed.untracked)
  let untracked = try await CodeSource.load("new.txt", in: repo, against: "HEAD")
  #expect(untracked.untracked && untracked.diff.isEmpty)
  await #expect(throws: CodeSource.Unreadable.self) { try await CodeSource.load("bin.png", in: repo, against: "HEAD") }
  await #expect(throws: CodeSource.Unreadable.self) { try await CodeSource.load("../escape.txt", in: repo, against: "HEAD") }
  let files = try await CodeSource.files(in: repo)
  #expect(Set(files) == ["a.txt", "new.txt", "bin.png"])
  let changes = try await CodeSource.changes(in: repo, against: "HEAD")
  #expect(Set(changes.map(\.path)) == ["a.txt", "new.txt", "bin.png"])
  let hits = try await CodeSource.definitions(of: "four", in: repo, from: nil)
  #expect(hits.isEmpty)
}

@Test func onlyFilesWorthShowingAreFollowed() async throws {
  let repo = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yatty-follow-\(UUID().uuidString)").path
  defer { try? FileManager.default.removeItem(atPath: repo) }
  _ = await Run.run("/usr/bin/env", ["git", "init", "-q", repo])
  let fm = FileManager.default
  for dir in ["build", "src", "vendor/lib", "vendor/lib/.git"] { try fm.createDirectory(atPath: repo + "/" + dir, withIntermediateDirectories: true) }
  try "build/\n*.log\n".write(toFile: repo + "/.gitignore", atomically: true, encoding: .utf8)
  for file in ["build/out.o", "src/a.swift", "a.log", "vendor/lib/x.c", "src/b.swift"] {
    try "x\n".write(toFile: repo + "/" + file, atomically: true, encoding: .utf8)
  }
  // Ignored files, folders, a repository inside this one, and a file gone by now don't count.
  let followed = await CodeSource.followable(
    ["build/out.o", "src/a.swift", "a.log", "vendor/lib/x.c", "src", "gone.swift", "src/b.swift"], in: repo)
  #expect(followed == ["src/a.swift", "src/b.swift"])
}

@Test func commentsGoOnlyToARunningAgent() {
  #expect(CodeAgent.pane(in: ["0", "a1"], focused: "0", reporting: ["a1"]) == "a1")
  #expect(CodeAgent.pane(in: ["0", "a1"], focused: "a1", reporting: ["0", "a1"]) == "a1")
  // No agent reports from the tab: never the shell that's focused.
  #expect(CodeAgent.pane(in: ["0", "a1"], focused: "0", reporting: []) == nil)
  // One asking the user something: Enter would answer it, so wait.
  #expect(CodeAgent.pane(in: ["0", "a1"], focused: "0", reporting: ["a1"], asking: ["a1"]) == nil)
  #expect(CodeAgent.pane(in: ["0", "a1"], focused: "a1", reporting: ["0", "a1"], asking: ["0"]) == "a1")
}
