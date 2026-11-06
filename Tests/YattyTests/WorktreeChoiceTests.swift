import Foundation
import Testing

@testable import Yatty

private func pr(_ number: Int, head: String, fork: Bool) -> OpenPullRequest {
  OpenPullRequest(
    number: number, title: "t", headRefName: head, isCrossRepository: fork,
    author: .init(login: "octo"))
}

@Test func prBranchNameAvoidsExistingLocalBranch() {
  // A fork's branch named like one of ours gets its own name.
  #expect(NewWorktreeChoice.branchName(for: pr(7, head: "main", fork: true), existing: ["main"]) == "pr/7-main")
  // Our own PR's branch is the branch we already have.
  #expect(NewWorktreeChoice.branchName(for: pr(8, head: "feature/x", fork: false), existing: ["feature/x"]) == "feature/x")
  #expect(NewWorktreeChoice.branchName(for: pr(9, head: "fix/y", fork: true), existing: []) == "fix/y")
}

@Test func choiceBranchesAndDirectories() {
  let existing: Set<String> = ["main"]
  #expect(NewWorktreeChoice.newBranch(name: "feature/login", base: "origin/main").branch(existing: existing) == "feature/login")
  #expect(NewWorktreeChoice.remoteBranch(remote: "origin", branch: "fix/crash").branch(existing: existing) == "fix/crash")
  #expect(NewWorktreeChoice.existingBranch("release").branch(existing: existing) == "release")
  #expect(NewWorktreeChoice.pullRequest(pr(7, head: "main", fork: true)).branch(existing: existing) == "pr/7-main")
  #expect(NewWorktreeChoice.pullRequest(pr(7, head: "main", fork: true)).directoryName(existing: existing) == "pr-7-main")
}

@Test func labelsDecodeWhenMissing() throws {
  let state = try JSONDecoder().decode(StoredState.self, from: Data(#"{"repos":[]}"#.utf8))
  #expect(state.labels.isEmpty)
  let labelled = try JSONDecoder().decode(StoredState.self, from: Data(#"{"labels":{"/r/.worktrees/x":"Login"}}"#.utf8))
  #expect(labelled.labels == ["/r/.worktrees/x": "Login"])
}
