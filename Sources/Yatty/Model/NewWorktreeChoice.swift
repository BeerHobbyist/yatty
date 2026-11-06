import Foundation

/// What a new worktree starts from, as picked in the New Worktree sheet.
enum NewWorktreeChoice: Hashable {
  case newBranch(name: String, base: String)
  /// A local branch.
  case existingBranch(String)
  /// `origin/x` and the like: checked out as a local `x` tracking it.
  case remoteBranch(remote: String, branch: String)
  case pullRequest(OpenPullRequest)

  /// The local branch the worktree has checked out.
  var branch: String {
    switch self {
    case .newBranch(let name, _): name
    case .existingBranch(let name): name
    case .remoteBranch(_, let branch): branch
    case .pullRequest(let pr): Self.branchName(for: pr)
    }
  }

  var directoryName: String { Git.directoryName(for: branch) }

  /// Our own pull request's branch is its head branch. A fork's is always
  /// `pr/<n>-<head>`: its head name may be one of ours (`main`), and a name
  /// that never depends on which branches exist can't flip once it does.
  static func branchName(for pr: OpenPullRequest) -> String {
    pr.isCrossRepository ? "pr/\(pr.number)-\(pr.headRefName)" : pr.headRefName
  }
}
