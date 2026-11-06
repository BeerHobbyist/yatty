import SwiftUI

/// A worktree's pull request: `#N` tinted by its checks, `draft` for one,
/// `✓#N` once merged. A click shows it in the inspector.
struct PullRequestBadge: View {
  let pullRequest: BranchPullRequest
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(label)
        .font(.caption.monospacedDigit())
        .foregroundStyle(tint)
    }
    .buttonStyle(.borderless)
    .fixedSize()
    .layoutPriority(1)
    .help(pullRequest.title.isEmpty ? "Pull request #\(pullRequest.number)" : pullRequest.title)
  }

  private var label: String {
    if pullRequest.merged { return "✓#\(pullRequest.number)" }
    return "#\(pullRequest.number)" + (pullRequest.isDraft ? " draft" : "")
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
