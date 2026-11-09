import Foundation
import Testing

@testable import Yatty

@Test func targetsBecomeDiffArguments() {
  #expect(DiffTarget.working.args == [])
  #expect(DiffTarget.staged.args == ["--staged"])
  #expect(DiffTarget.base("origin/main").args == ["origin/main...HEAD"])
  #expect(DiffTarget.ref("v1.2").args == ["v1.2"])
  #expect(DiffTarget.range("a1..b2").args == ["a1..b2"])
}

@Test func pagersCantQuitOnShortDiffs() {
  for viewer in [DiffViewer.git, .delta, .difftastic, .diffnav] {
    #expect(viewer.command(args: []).contains("LESS=R"))
  }
  // The user's own core.pager never applies.
  #expect(DiffViewer.git.command(args: []).contains("core.pager=less -R"))
  #expect(DiffViewer.difftastic.command(args: []).contains("diff.external=difft"))
}

@Test func guardedCommandQuotesArguments() {
  let command = DiffViewers.command(.git, args: ["it's a ref"])
  #expect(command.hasPrefix("if 'git' 'diff' '--quiet' 'it'\\''s a ref'; then"))
  #expect(command.contains("No changes to show."))
}

@Test func viewerResolution() {
  #expect(DiffViewers.resolve(nil, available: [.delta, .git]) == .delta)
  #expect(DiffViewers.resolve(.hunk, available: [.delta, .git]) == .delta)
  #expect(DiffViewers.resolve(.diffview, available: [.diffview, .git]) == .diffview)
  #expect(DiffViewers.resolve(nil, available: [.diffview, .git]) == .git)
  #expect(DiffViewers.next(after: .delta, available: [.hunk, .delta, .git]) == .git)
  #expect(DiffViewers.next(after: .git, available: [.hunk, .delta, .git]) == .hunk)
}

@Test func pickingCommitsEitherWay() {
  // Newest first, as the list shows them.
  let commits = [
    Commit(sha: "c3", short: "c3", parent: "c2", subject: "three"),
    Commit(sha: "c2", short: "c2", parent: "c1", subject: "two"),
    Commit(sha: "c1", short: "c1", parent: "c0", subject: "one"),
  ]
  #expect(DiffViewers.pickCommits(commits, cursor: 1, mark: nil)?.range == "c1..HEAD")
  #expect(DiffViewers.pickCommits(commits, cursor: 0, mark: "c1")?.range == "c0..c3")
  #expect(DiffViewers.pickCommits(commits, cursor: 2, mark: "c3")?.range == "c0..c3")
  #expect(DiffViewers.pickCommits(commits, cursor: 1, mark: "c2")?.label == "c2 · 1 commit")
  #expect(DiffViewers.pickCommits([], cursor: 0, mark: nil) == nil)
}

@Test func rootCommitDiffsAgainstTheEmptyTree() {
  let log = "aaa\u{1f}a\u{1f}\u{1f}first\nbbb\u{1f}b\u{1f}aaa\u{1f}second\n"
  let commits = Git.parseCommits(log, emptyTree: "4b825dc")
  #expect(commits.map(\.parent) == ["4b825dc", "aaa"])
  #expect(commits.map(\.subject) == ["first", "second"])
}

@Test func guardedGitDisablesWhatRepoConfigCouldRun() {
  let overrides = GuardedGit.overrides(filters: ["x", "a=b"], hooks: ["evil"])
  let pairs = Set(overrides.map { "\($0.key)=\($0.value)" })
  for setting in [
    "core.fsmonitor=false", "core.hooksPath=/dev/null", "diff.external=", "core.quotePath=false",
    "log.showSignature=false", "diff.submodule=short", "diff.ignoreSubmodules=dirty",
    "filter.x.clean=", "filter.x.process=", "filter.a=b.smudge=", "filter.a=b.required=false", "hook.evil.enabled=false",
  ] {
    #expect(pairs.contains(setting), "missing \(setting)")
  }
  // Through the environment, where a key can hold "=" (`-c` splits at the first).
  let env = GuardedGit.environment(overrides)
  #expect(env["GIT_CONFIG_COUNT"] == String(overrides.count))
  let index = overrides.firstIndex { $0.key == "filter.a=b.clean" }!
  #expect(env["GIT_CONFIG_KEY_\(index)"] == "filter.a=b.clean" && env["GIT_CONFIG_VALUE_\(index)"] == "")
  #expect(env["GIT_NO_LAZY_FETCH"] == "1")
  #expect(GitDiff.flags.contains("--no-ext-diff") && GitDiff.flags.contains("--no-textconv"))
  #expect(GitDiff.flags.contains("--submodule=short") && GitDiff.flags.contains("--ignore-submodules=dirty"))
}

@Test func onlyWhatAnAgentCouldWriteIsTurnedOff() {
  // `git config --show-scope --includes -z --get-regexp`: scope NUL key LF value NUL.
  let records: [(String, String)] = [
    ("local", "filter.x.clean"), ("global", "filter.lfs.clean"), ("worktree", "filter.a.b.process"),
    ("local", "filter.x.smudge"), ("command", "filter.y.clean"), ("local", "filter.foo"),
    ("local", "filter..clean"), ("local", "filter.a b.clean"), ("local", "filter.a=b.clean"),
    ("local", "hook.evil.command"), ("local", "hook.evil.event"), ("global", "hook.mine.command"),
  ]
  let config = records.map { "\($0.0)\u{0}\($0.1)\nsome value\u{0}" }.joined()
  let found = GuardedGit.repositoryConfig(config)
  #expect(found.filters == ["x", "a.b", "a b", "a=b"])
  #expect(found.hooks == ["evil"])
}

/// A repository whose config tries everything the reviewer found: none of it may run.
@Test func hostileRepositoryRunsNothing() async throws {
  let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yatty-hostile-\(UUID().uuidString)")
  let repo = root.appendingPathComponent("repo").path
  let marker = root.appendingPathComponent("ran").path
  let hooks = root.appendingPathComponent("hooks").path
  try FileManager.default.createDirectory(atPath: hooks, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let script = root.appendingPathComponent("evil.sh").path
  try "#!/bin/sh\necho \"$0 $*\" >> '\(marker)'\ncat\n".write(toFile: script, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
  try FileManager.default.copyItem(atPath: script, toPath: hooks + "/post-index-change")
  func git(_ args: String...) async { _ = await Run.run("/usr/bin/env", ["git", "-C", repo] + args) }
  _ = await Run.run("/usr/bin/env", ["git", "init", "-q", repo])
  try "* filter=x\n".write(toFile: repo + "/.gitattributes", atomically: true, encoding: .utf8)
  try "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
  await git("add", ".")
  await git("-c", "user.name=y", "-c", "user.email=y@y", "commit", "-qm", "init")
  // What an agent would plant once the repository exists.
  await git("config", "core.fsmonitor", script)
  await git("config", "core.hooksPath", hooks)
  await git("config", "filter.x.clean", script)
  await git("config", "log.showSignature", "true")
  await git("config", "hook.evil.command", script)
  await git("config", "--add", "hook.evil.event", "post-index-change")
  await git("config", "filter.a=b.clean", script)
  await git("config", "filter.a b.clean", script)
  try "* filter=x\n*.md filter=a=b\n*.txt filter=\"a b\"\n".write(toFile: repo + "/.gitattributes", atomically: true, encoding: .utf8)
  try "doc\n".write(toFile: repo + "/b.md", atomically: true, encoding: .utf8)
  _ = await Run.run("/usr/bin/env", ["touch", repo + "/a.txt"])
  try "two\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
  try "new\n".write(toFile: repo + "/new.txt", atomically: true, encoding: .utf8)

  let diff = try await GitDiff.text(in: repo, target: .working)
  _ = await Git.status(path: repo)
  #expect(diff.contains("+two"))
  #expect(diff.contains("new.txt"))
  #expect(!FileManager.default.fileExists(atPath: marker), "ran: \((try? String(contentsOfFile: marker, encoding: .utf8)) ?? "")")
}

@Test func yattyIsTheDefaultViewer() {
  #expect(DiffViewers.available(in: "/nonexistent").first == .yatty)
  #expect(DiffViewers.resolve(nil, available: [.yatty, .delta, .git]) == .yatty)
  #expect(DiffViewers.resolve(.delta, available: [.yatty, .delta, .git]) == .delta)
}

@Test func diffRequestsSurviveRestoration() throws {
  let request = DiffRequest(worktreePath: "/r/.worktrees/login", worktreeName: "login", target: .base("origin/main"))
  let decoded = try JSONDecoder().decode(DiffRequest.self, from: JSONEncoder().encode(request))
  #expect(decoded == request)
}

@Test func aSandboxedAgentsDiffStaysInTheSandbox() {
  // The window runs git in the app; a sandboxed agent's diff runs in a
  // sandboxed terminal tab instead, whatever the user's viewer.
  #expect(DiffViewers.forSandbox(.yatty, available: [.yatty, .delta, .git]) == .delta)
  #expect(DiffViewers.forSandbox(.yatty, available: [.yatty]) == .git)
  #expect(DiffViewers.forSandbox(.hunk, available: [.yatty, .hunk, .git]) == .hunk)
}
