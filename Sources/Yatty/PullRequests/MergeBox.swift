import Foundation

/// One line of the merge box: a short verdict, a muted detail, a colour.
struct MergeBoxLine: Equatable, Sendable {
  var verdict: String
  var detail: String
  var tone: Tone
}

/// The PR panel's merge box, as GitHub shows it under a pull request:
/// reviews, checks, conflicts — or how it finished.
enum MergeBox {
  static func reviews(_ d: PullRequestDetails) -> MergeBoxLine {
    let latest = d.latestReviews
    let verdict: (text: String, state: String?, tone: Tone) =
      switch d.reviewDecision {
      case "CHANGES_REQUESTED": ("Changes requested", "CHANGES_REQUESTED", .bad)
      case "APPROVED": ("Approved", "APPROVED", .good)
      case "REVIEW_REQUIRED": ("Review required", nil, .warn)
      default:
        if latest.contains(where: { $0.state == "CHANGES_REQUESTED" }) {
          ("Changes requested", "CHANGES_REQUESTED", .bad)
        } else if latest.contains(where: { $0.state == "APPROVED" }) {
          ("Approved", "APPROVED", .good)
        } else if !d.reviewRequests.isEmpty {
          ("Review requested", nil, .warn)
        } else if latest.isEmpty {
          ("No reviews yet", nil, .muted)
        } else {
          ("Commented", "COMMENTED", .muted)
        }
      }
    // Who said what the verdict says first, by name alone; then the others
    // with what they said; then who hasn't yet.
    let agreeing = latest.filter { $0.state == verdict.state }.map { $0.author?.login ?? "ghost" }
    let others = latest.filter { $0.state != verdict.state }.map { "\($0.author?.login ?? "ghost") \(said($0.state))" }
    let waiting = d.reviewRequests.map { "\($0.displayName) waiting" }
    return MergeBoxLine(verdict: verdict.text, detail: (agreeing + others + waiting).joined(separator: " · "), tone: verdict.tone)
  }

  static func checks(_ d: PullRequestDetails) -> MergeBoxLine {
    let checks = d.statusCheckRollup.map { ($0.displayName, PullRequests.checkState($0)) }
    guard !checks.isEmpty else { return MergeBoxLine(verdict: "No checks", detail: "", tone: .muted) }
    func named(_ state: CheckState) -> [String] { checks.filter { $0.1 == state }.map(\.0) }
    let failing = named(.fail), running = named(.pending), passed = named(.pass), skipped = named(.skipped)
    func plural(_ n: Int) -> String { n == 1 ? "check" : "checks" }
    let verdict: (String, Tone) =
      if !failing.isEmpty { ("\(failing.count) \(plural(failing.count)) failing", .bad) }
      else if !running.isEmpty { ("\(running.count) \(plural(running.count)) running", .warn) }
      else { ("All checks passed", .good) }
    var detail: [String]
    if failing.isEmpty && running.isEmpty {
      detail = ["\(passed.count) passed"] + (skipped.isEmpty ? [] : ["\(skipped.count) skipped"])
    } else if checks.count <= 3 {
      detail = failing + running.map { "\($0) running" } + passed.map { "\($0) passed" } + skipped.map { "\($0) skipped" }
    } else {
      // Many: the failing by name, the rest counted.
      detail = failing
      if !running.isEmpty { detail.append("\(running.count) running") }
      if !passed.isEmpty { detail.append("\(passed.count) passed") }
      if !skipped.isEmpty { detail.append("\(skipped.count) skipped") }
    }
    return MergeBoxLine(verdict: verdict.0, detail: detail.joined(separator: " · "), tone: verdict.1)
  }

  static func conflicts(_ d: PullRequestDetails) -> MergeBoxLine {
    let base = "with \(d.baseRefName.isEmpty ? "the base branch" : d.baseRefName)"
    return switch d.mergeable {
    case "MERGEABLE": MergeBoxLine(verdict: "No conflicts", detail: base, tone: .good)
    case "CONFLICTING": MergeBoxLine(verdict: "Conflicts", detail: base, tone: .bad)
    default: MergeBoxLine(verdict: "Checking…", detail: "", tone: .muted)
    }
  }

  /// How it ended, once it has: the whole box is then this one line.
  static func finished(_ d: PullRequestDetails) -> MergeBoxLine? {
    switch d.state.uppercased() {
    case "MERGED": MergeBoxLine(verdict: "Merged into \(d.baseRefName.isEmpty ? "the base branch" : d.baseRefName)", detail: "", tone: .merged)
    case "CLOSED": MergeBoxLine(verdict: "Closed without merging", detail: "", tone: .muted)
    default: nil
    }
  }

  /// The author's login; GitHub's "ghost" for a deleted account.
  static func author(_ d: PullRequestDetails) -> String { d.author?.login ?? "ghost" }

  private static func said(_ state: String) -> String {
    switch state {
    case "APPROVED": "approved"
    case "CHANGES_REQUESTED": "requested changes"
    case "DISMISSED": "dismissed"
    default: "commented"
    }
  }
}

extension PullRequests {
  /// "8s", "1m 12s", "2m", "1h 3m".
  static func durationLabel(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    switch total {
    case ..<60: return "\(total)s"
    case ..<3_600: return total % 60 == 0 ? "\(total / 60)m" : "\(total / 60)m \(total % 60)s"
    default: return total % 3_600 / 60 == 0 ? "\(total / 3_600)h" : "\(total / 3_600)h \(total % 3_600 / 60)m"
    }
  }

  /// The GitHub Actions run a check's link points into, for re-running it.
  static func actionsRun(_ link: String) -> (nameWithOwner: String, runID: String)? {
    guard let match = link.firstMatch(of: /^https:\/\/github\.com\/([^\/]+\/[^\/]+)\/actions\/runs\/(\d+)/) else { return nil }
    return (String(match.1), String(match.2))
  }
}

extension RawCheck {
  /// How long it ran, once it finished.
  var duration: TimeInterval? {
    guard let startedAt, let completedAt,
      let start = ISO8601DateFormatter().date(from: startedAt), let end = ISO8601DateFormatter().date(from: completedAt)
    else { return nil }
    return max(0, end.timeIntervalSince(start))
  }
}

/// What the merge box's button does now.
enum MergeButton: Equatable, Sendable {
  case merge(MergeMethod)
  case autoMerge(MergeMethod)
  /// Can't: why.
  case disabled(String)
}

extension MergeBox {
  /// Today's merge rules (`PullRequests.mergeOptions`), with the method used
  /// last when the repository still allows it, else its first.
  static func button(_ d: PullRequestDetails, settings: MergeSettings?, lastMethod: MergeMethod?) -> MergeButton {
    guard let settings else { return .disabled("Loading merge options…") }
    guard let method = lastMethod.flatMap({ settings.methods.contains($0) ? $0 : nil }) ?? settings.methods.first
    else { return .disabled("The repository allows no merge method") }
    let options = PullRequests.mergeOptions(d, settings: settings)
    if options.now { return .merge(method) }
    if options.auto { return .autoMerge(method) }
    return .disabled(options.reason ?? "It can't be merged from here.")
  }
}
