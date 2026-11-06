import Foundation

/// What a new worktree starts from, as picked in the New Worktree sheet.
enum NewWorktreeChoice: Hashable {
  case newBranch(name: String, base: String)
  /// A local branch.
  case existingBranch(String)
  /// `origin/x` and the like: checked out as a local `x` tracking it.
  case remoteBranch(remote: String, branch: String)
  case pullRequest(OpenPullRequest)

  /// The local branch the worktree has checked out. `existing`: the local
  /// branches there are.
  func branch(existing: Set<String>) -> String {
    switch self {
    case .newBranch(let name, _): name
    case .existingBranch(let name): name
    case .remoteBranch(_, let branch): branch
    case .pullRequest(let pr): Self.branchName(for: pr, existing: existing)
    }
  }

  func directoryName(existing: Set<String>) -> String {
    Git.directoryName(for: branch(existing: existing))
  }

  /// A pull request's branch is its head branch, unless that's one of ours
  /// already and the pull request comes from a fork: then `pr/<n>-<head>`.
  static func branchName(for pr: OpenPullRequest, existing: Set<String>) -> String {
    guard pr.isCrossRepository, existing.contains(pr.headRefName) else { return pr.headRefName }
    return "pr/\(pr.number)-\(pr.headRefName)"
  }
}
