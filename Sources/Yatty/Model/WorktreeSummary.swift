import Foundation

/// What the sidebar knows about a worktree, for its second line.
struct WorktreeFacts {
  var agent: AgentState?
  /// When its agent started waiting on the user.
  var waitingSince: Date?
  var pullRequest: BranchPullRequest?
  var status: GitStatus?
  var branch: String?
  /// The name the sidebar shows.
  var label: String
  /// `host:~/path`, for a directory on another machine.
  var remotePath: String?
  var disconnected: Bool
}

/// The sidebar's rules: a row's second line, the filter, the order of
/// "Needs you".
enum WorktreeSummary {
  /// The first fact that applies, in words: waiting on you, a pull request
  /// that wants attention, working, where a remote directory is, changes and
  /// sync, the branch when it isn't the name shown, else "up to date".
  static func secondLine(_ facts: WorktreeFacts, now: Date) -> String {
    if facts.agent == .needsAction {
      return facts.waitingSince.map { "waiting " + age($0, now: now) } ?? "waiting"
    }
    if let pr = facts.pullRequest {
      if pr.merged { return "merged · ready to close" }
      if pr.checks == .fail { return "PR #\(pr.number) · checks failing" }
      if pr.reviewDecision == "CHANGES_REQUESTED" { return "PR #\(pr.number) · changes requested" }
    }
    if facts.agent == .working { return "working" }
    if let remote = facts.remotePath { return facts.disconnected ? "disconnected" : remote }
    if let status = facts.status, let sync = sync(status) { return sync }
    if let branch = facts.branch, branch != facts.label { return branch }
    return "up to date"
  }

  /// `query` in the worktree's name, branch or project, ignoring case; an
  /// empty query matches everything.
  static func matches(_ query: String, name: String, branch: String?, project: String) -> Bool {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else { return true }
    return [name, branch ?? "", project].contains { $0.lowercased().contains(needle) }
  }

  /// Longest wait first.
  static func needsYouOrder(_ waiting: [(id: String, since: Date)]) -> [String] {
    waiting.enumerated()
      .sorted { ($0.element.since, $0.offset) < ($1.element.since, $1.offset) }
      .map(\.element.id)
  }

  private static func sync(_ status: GitStatus) -> String? {
    if status.changed == 0 {
      switch (status.ahead, status.behind) {
      case (0, 0): return nil
      case (let ahead, 0): return "↑\(ahead) ahead"
      case (0, let behind): return "↓\(behind) behind"
      case (let ahead, let behind): return "↑\(ahead) · ↓\(behind)"
      }
    }
    var parts = ["\(status.changed) change\(status.changed == 1 ? "" : "s")"]
    if status.ahead > 0 { parts.append("↑\(status.ahead)") }
    if status.behind > 0 { parts.append("↓\(status.behind)") }
    return parts.joined(separator: " · ")
  }

  private static func age(_ since: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(since)))
    switch seconds {
    case ..<60: return "<1m"
    case ..<3_600: return "\(seconds / 60)m"
    case ..<86_400: return "\(seconds / 3_600)h"
    default: return "\(seconds / 86_400)d"
    }
  }
}
