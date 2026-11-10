import SwiftUI

/// A sidebar row's icon: its pull request's state when it has one (GitHub's
/// icon, coloured by its checks; purple once merged), else what it is.
struct WorktreeIcon: Equatable {
  enum Tint: Equatable {
    case accent, purple, green, red, orange, secondary

    var color: Color {
      switch self {
      case .accent: .accentColor
      case .purple: .purple
      case .green: .green
      case .red: .red
      case .orange: .orange
      case .secondary: .secondary
      }
    }
  }

  var name: Octicon.Name
  var tint: Tint

  static func of(isMain: Bool, isRemote: Bool, pullRequest: BranchPullRequest?) -> WorktreeIcon {
    guard let pullRequest else {
      return WorktreeIcon(name: isRemote ? .fileDirectory : isMain ? .home : .gitBranch, tint: .accent)
    }
    if pullRequest.merged { return WorktreeIcon(name: .gitMerge, tint: .purple) }
    let tint: Tint =
      switch pullRequest.checks {
      case .pass: .green
      case .fail: .red
      case .pending: .orange
      case .skipped, nil: .secondary
      }
    return WorktreeIcon(name: pullRequest.isDraft ? .gitPullRequestDraft : .gitPullRequest, tint: tint)
  }
}
