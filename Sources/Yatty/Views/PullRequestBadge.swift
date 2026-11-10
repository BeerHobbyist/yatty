import SwiftUI

/// The pull request's number on the right of its row; the row's icon shows
/// its state. A click opens the pull request panel.
struct PullRequestBadge: View {
  let pullRequest: BranchPullRequest
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text("#\(pullRequest.number)").font(.caption.weight(.medium).monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.borderless)
    .fixedSize()
    .layoutPriority(1)
    .help(
      (pullRequest.merged ? "Merged: " : pullRequest.isDraft ? "Draft: " : "")
        + (pullRequest.title.isEmpty ? "Pull request #\(pullRequest.number)" : pullRequest.title))
  }
}
