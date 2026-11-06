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
