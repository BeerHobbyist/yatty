import Foundation
import Testing

@testable import Yatty

private func pr(_ number: Int, head: String, fork: Bool) -> OpenPullRequest {
  OpenPullRequest(
    number: number, title: "t", headRefName: head, isCrossRepository: fork,
    author: .init(login: "octo"))
}

@Test func prBranchNameIsStable() {
  // A fork's branch never takes a name of ours, whatever branches exist.
  #expect(NewWorktreeChoice.branchName(for: pr(7, head: "main", fork: true)) == "pr/7-main")
  #expect(NewWorktreeChoice.branchName(for: pr(9, head: "fix/y", fork: true)) == "pr/9-fix/y")
  // Our own pull request's branch is the branch itself.
  #expect(NewWorktreeChoice.branchName(for: pr(8, head: "feature/x", fork: false)) == "feature/x")
}

@Test func choiceBranchesAndDirectories() {
  #expect(NewWorktreeChoice.newBranch(name: "feature/login", base: "origin/main").branch == "feature/login")
  #expect(NewWorktreeChoice.remoteBranch(remote: "origin", branch: "fix/crash").branch == "fix/crash")
  #expect(NewWorktreeChoice.existingBranch("release").branch == "release")
  #expect(NewWorktreeChoice.pullRequest(pr(7, head: "main", fork: true)).directoryName == "pr-7-main")
}

@Test func labelsDecodeWhenMissing() throws {
  let state = try JSONDecoder().decode(StoredState.self, from: Data(#"{"repos":[]}"#.utf8))
  #expect(state.labels.isEmpty)
  let labelled = try JSONDecoder().decode(StoredState.self, from: Data(#"{"labels":{"/r/.worktrees/x":"Login"}}"#.utf8))
  #expect(labelled.labels == ["/r/.worktrees/x": "Login"])
}
