import SwiftUI

/// A worktree's pull request: GitHub's icon for its state and `#N`, tinted
/// by its checks, purple once merged. A click shows it in the inspector.
struct PullRequestBadge: View {
  let pullRequest: BranchPullRequest
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 2) {
        Octicon(icon, size: 10)
        Text("#\(pullRequest.number)").font(.caption.weight(.medium).monospacedDigit())
      }
      .foregroundStyle(tint)
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(Capsule().fill(tint.opacity(0.16)))
    }
    .buttonStyle(.borderless)
    .fixedSize()
    .layoutPriority(1)
    .help(
      (pullRequest.merged ? "Merged: " : pullRequest.isDraft ? "Draft: " : "")
        + (pullRequest.title.isEmpty ? "Pull request #\(pullRequest.number)" : pullRequest.title))
  }

  private var icon: Octicon.Name {
    pullRequest.merged ? .gitMerge : pullRequest.isDraft ? .gitPullRequestDraft : .gitPullRequest
  }

  private var tint: Color {
    if pullRequest.merged { return .purple }
    switch pullRequest.checks {
    case .pass: return .green
    case .fail: return .red
    case .pending: return .orange
    case .skipped, nil: return .secondary
    }
  }
}
