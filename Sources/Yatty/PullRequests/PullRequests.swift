import Foundation

enum CheckState: String, Sendable {
  case pass, fail, pending, skipped
}

/// One entry of `statusCheckRollup`: a check run (status + conclusion) or a
/// commit status from another CI system (state).
struct RawCheck: Decodable, Equatable, Sendable {
  var state: String?
  var status: String?
  var conclusion: String?
  var name: String?
  var context: String?
  var detailsUrl: String?
  var targetUrl: String?

  var displayName: String { name ?? context ?? "check" }
  var link: URL? { (detailsUrl ?? targetUrl).flatMap(URL.init(string:)) }
}

/// What a worktree row's badge shows about its branch's pull request.
struct BranchPullRequest: Equatable, Sendable {
  var number: Int
  var title: String
  var url: String
  var isDraft: Bool
  var merged: Bool
  var checks: CheckState?
  var headOid: String
}

/// A conversation on the diff. GitHub folds resolved ones away.
struct ReviewThread: Equatable, Sendable, Identifiable {
  struct Comment: Equatable, Sendable {
    var author: String
    var body: String
    var createdAt: String
    var url: String?
  }

  var id: String
  var path: String
  var line: Int?
  /// Where a comment on several lines starts.
  var startLine: Int? = nil
  /// On the removed side of the diff: its lines are the base branch's.
  var onBase = false
  var isResolved: Bool
  var isOutdated: Bool
  var comments: [Comment]

  /// When it last moved: its newest comment.
  var date: String { comments.map(\.createdAt).max() ?? "" }

  /// `path:line`, or `path:start-end` for several lines.
  var location: String {
    guard let line else { return path }
    if let startLine, startLine != line { return "\(path):\(startLine)-\(line)" }
    return "\(path):\(line)"
  }

  static let query = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewThreads(first: 100) {
            nodes {
              id isResolved isOutdated path line originalLine startLine originalStartLine diffSide startDiffSide
              comments(first: 50) { nodes { author { login } body createdAt url } }
            }
          }
        }
      }
    }
    """

  /// `query`'s answer; nil when it isn't one.
  static func parse(_ data: Data) -> [ReviewThread]? {
    struct Response: Decodable {
      struct Node: Decodable {
        struct Comments: Decodable { var nodes: [CommentNode] }
        struct CommentNode: Decodable {
          struct Author: Decodable { var login: String }
          var author: Author?
          var body: String
          var createdAt: String
          var url: String?
        }
        var id: String
        var isResolved: Bool
        var isOutdated: Bool
        var path: String
        var line: Int?
        var originalLine: Int?
        var startLine: Int?
        var originalStartLine: Int?
        var diffSide: String?
        var startDiffSide: String?
        var comments: Comments
      }
      struct Threads: Decodable { var nodes: [Node] }
      struct PullRequest: Decodable { var reviewThreads: Threads }
      struct Repository: Decodable { var pullRequest: PullRequest? }
      struct Payload: Decodable { var repository: Repository? }
      var data: Payload?
    }
    guard let nodes = (try? JSONDecoder().decode(Response.self, from: data))?.data?.repository?.pullRequest?
      .reviewThreads.nodes
    else { return nil }
    return nodes.map { node in
      ReviewThread(
        id: node.id, path: node.path, line: node.line ?? node.originalLine,
        // A range from removed lines into added ones mixes two files' numbers: its end alone.
        startLine: node.startDiffSide.map { $0 != node.diffSide } == true
          ? nil : node.line == nil ? node.originalStartLine : node.startLine,
        onBase: node.diffSide == "LEFT",
        isResolved: node.isResolved, isOutdated: node.isOutdated,
        comments: node.comments.nodes.map {
          Comment(author: $0.author?.login ?? "?", body: $0.body, createdAt: $0.createdAt, url: $0.url)
        })
    }
  }
}

/// `gh pr view --json …` for the inspector.
struct PullRequestDetails: Decodable, Equatable, Sendable {
  struct Person: Decodable, Equatable, Sendable { var login: String }
  struct Review: Decodable, Equatable, Sendable {
    var author: Person?
    var state: String
    var submittedAt: String?
    var body: String?
  }
  /// A user (`login`) or a team (`name`).
  struct ReviewRequest: Decodable, Equatable, Sendable {
    var login: String?
    var name: String?
    var displayName: String { login ?? name ?? "?" }
  }
  struct Comment: Decodable, Equatable, Sendable {
    var author: Person?
    var body: String
    var createdAt: String
    var url: String?
  }
  struct Label: Decodable, Equatable, Sendable {
    var name: String
    var color: String?
  }

  var number: Int
  var title: String
  var url: String
  /// OPEN, MERGED or CLOSED.
  var state: String
  var isDraft: Bool
  var author: Person?
  var baseRefName: String
  var headRefName: String
  var headRefOid: String
  var additions: Int
  var deletions: Int
  var changedFiles: Int
  var updatedAt: String
  /// MERGEABLE, CONFLICTING or UNKNOWN.
  var mergeable: String
  /// CLEAN, BEHIND, BLOCKED, DIRTY, UNSTABLE, HAS_HOOKS, UNKNOWN…
  var mergeStateStatus: String
  /// APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or empty.
  var reviewDecision: String
  var latestReviews: [Review]
  var reviewRequests: [ReviewRequest]
  var reviews: [Review]
  var comments: [Comment]
  var labels: [Label]
  var statusCheckRollup: [RawCheck]
  var body: String

  static let fields =
    "number,title,url,state,isDraft,author,baseRefName,headRefName,headRefOid,additions,deletions,"
    + "changedFiles,updatedAt,mergeable,mergeStateStatus,reviewDecision,latestReviews,reviewRequests,"
    + "reviews,comments,labels,statusCheckRollup,body"
}

enum MergeMethod: String, CaseIterable, Codable, Sendable {
  case merge, squash, rebase

  var title: String {
    switch self {
    case .merge: "Create a merge commit"
    case .squash: "Squash and merge"
    case .rebase: "Rebase and merge"
    }
  }
}

struct MergeSettings: Equatable, Sendable {
  var methods: [MergeMethod]
  var autoMerge: Bool

  /// From `GET /repos/{repo}`. GitHub leaves the `allow_*` fields out for
  /// people without push access: then every method is offered and GitHub
  /// has the final say.
  static func decode(_ json: [String: Any]) -> MergeSettings {
    func allowed(_ key: String) -> Bool { (json[key] as? Bool) != false }
    let methods = MergeMethod.allCases.filter {
      allowed($0 == .merge ? "allow_merge_commit" : "allow_\($0.rawValue)_merge")
    }
    return MergeSettings(methods: methods, autoMerge: json["allow_auto_merge"] as? Bool == true)
  }
}

enum Tone: Sendable {
  case good, warn, bad, muted, merged
}

/// agentree's pull request rules (src/services/pr.ts, gh.ts).
enum PullRequests {
  static func checkState(_ check: RawCheck) -> CheckState {
    if let state = check.state {
      switch state.uppercased() {
      case "SUCCESS": return .pass
      case "FAILURE", "ERROR": return .fail
      default: return .pending  // PENDING, EXPECTED
      }
    }
    if let status = check.status, status.uppercased() != "COMPLETED" { return .pending }
    switch (check.conclusion ?? "").uppercased() {
    case "SUCCESS": return .pass
    case "NEUTRAL", "SKIPPED", "STALE": return .skipped
    case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": return .fail
    default: return .pending
    }
  }

  /// Any failure wins, then anything still running.
  static func summarize(_ states: [CheckState]) -> CheckState? {
    if states.contains(.fail) { return .fail }
    if states.contains(.pending) { return .pending }
    if states.contains(.pass) { return .pass }
    return states.isEmpty ? nil : .skipped
  }

  /// A merged pull request found by branch name is this branch's only when
  /// HEAD is its head, one of its commits, or past its head — and its merge
  /// isn't in the branch already (a branch started from main after it).
  static func isThisBranchs(
    head: String, prHead: String?, prCommits: [String], prHeadIsAncestorOfHead: Bool,
    mergeCommitIsAncestorOfHead: Bool
  ) -> Bool {
    let ours = prHead == head || prCommits.contains(head) || prHeadIsAncestorOfHead
    return ours && !mergeCommitIsAncestorOfHead
  }

  static func mergeStatus(_ d: PullRequestDetails) -> (label: String, tone: Tone) {
    let base = d.baseRefName.isEmpty ? "the base branch" : d.baseRefName
    switch d.state.uppercased() {
    case "MERGED": return ("Merged", .merged)
    case "CLOSED": return ("Closed without merging", .bad)
    default: break
    }
    if d.isDraft { return ("Draft — not ready for review", .muted) }
    let checks = summarize(d.statusCheckRollup.map(checkState))
    if d.mergeable == "CONFLICTING" || d.mergeStateStatus == "DIRTY" { return ("Merge conflicts with \(base)", .bad) }
    switch d.mergeStateStatus {
    case "BEHIND":
      return ("Branch is behind \(base)", .warn)
    case "BLOCKED":
      if d.reviewDecision == "CHANGES_REQUESTED" { return ("Blocked: changes requested", .bad) }
      if d.reviewDecision == "REVIEW_REQUIRED" { return ("Blocked: review required", .warn) }
      if checks == .fail { return ("Blocked: failing checks", .bad) }
      if checks == .pending { return ("Blocked: checks running", .warn) }
      return ("Blocked by branch protection", .warn)
    case "UNSTABLE":
      return ("Mergeable, but some checks failed", .warn)
    case "CLEAN", "HAS_HOOKS":
      return ("Ready to merge", .good)
    default:
      return checks == .pending ? ("Checks running", .warn) : ("Checking mergeability…", .muted)
    }
  }

  /// Whether it can be merged from here now, set to merge once ready
  /// (auto-merge), or neither — with why.
  static func mergeOptions(_ d: PullRequestDetails, settings: MergeSettings) -> (now: Bool, auto: Bool, reason: String?) {
    let status = mergeStatus(d).label
    guard d.state.uppercased() == "OPEN", !d.isDraft else { return (false, false, status) }
    if d.mergeable == "CONFLICTING" || d.mergeStateStatus == "DIRTY" { return (false, false, status) }
    switch d.mergeStateStatus {
    case "BLOCKED", "BEHIND":
      return settings.autoMerge
        ? (false, true, status) : (false, false, "\(status) — and auto-merge is off for this repo")
    default:
      // CLEAN, HAS_HOOKS, UNSTABLE, UNKNOWN: GitHub decides.
      return (true, false, nil)
    }
  }

  /// "just now", "5m ago", "3h ago", "2d ago", or the date past a month.
  static func relativeTime(_ iso: String, now: Date = Date()) -> String {
    guard let date = ISO8601DateFormatter().date(from: iso) else { return "" }
    let seconds = max(0, Int(now.timeIntervalSince(date).rounded()))
    if seconds < 45 { return "just now" }
    if seconds < 3600 { return "\(Int((Double(seconds) / 60).rounded()))m ago" }
    if seconds < 86_400 { return "\(Int((Double(seconds) / 3600).rounded()))h ago" }
    if seconds < 30 * 86_400 { return "\(Int((Double(seconds) / 86_400).rounded()))d ago" }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
  }
}
