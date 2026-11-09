import Foundation
import Testing

@testable import Yatty

private func check(_ name: String, status: String = "COMPLETED", conclusion: String? = nil) -> RawCheck {
  RawCheck(state: nil, status: status, conclusion: conclusion, name: name, context: nil, detailsUrl: nil, targetUrl: nil)
}

private func review(_ login: String, _ state: String) -> PullRequestDetails.Review {
  .init(author: .init(login: login), state: state, submittedAt: "2026-11-06T08:00:00Z", body: "")
}

private func details(
  state: String = "OPEN", mergeable: String = "MERGEABLE", status: String = "BLOCKED", draft: Bool = false,
  decision: String = "",
  reviews: [PullRequestDetails.Review] = [], requests: [String] = [], checks: [RawCheck] = [],
  author: String? = "octo"
) -> PullRequestDetails {
  PullRequestDetails(
    number: 42, title: "t", url: "u", state: state, isDraft: draft, author: author.map { .init(login: $0) },
    baseRefName: "main", headRefName: "feature/login", headRefOid: "h", additions: 1, deletions: 0, changedFiles: 1,
    updatedAt: "", mergeable: mergeable, mergeStateStatus: status, reviewDecision: decision,
    latestReviews: reviews, reviewRequests: requests.map { .init(login: $0, name: nil) }, reviews: [], comments: [],
    labels: [], statusCheckRollup: checks, body: "")
}

@Test func mergeBoxReviewLine() {
  let mixed = details(
    decision: "CHANGES_REQUESTED", reviews: [review("lead", "CHANGES_REQUESTED"), review("reviewer", "APPROVED")],
    requests: ["security-team"])
  #expect(MergeBox.reviews(mixed) == MergeBoxLine(
    verdict: "Changes requested", detail: "lead · reviewer approved · security-team waiting", tone: .bad))
  let approved = details(decision: "APPROVED", reviews: [review("reviewer", "APPROVED")])
  #expect(MergeBox.reviews(approved) == MergeBoxLine(verdict: "Approved", detail: "reviewer", tone: .good))
  let required = details(decision: "REVIEW_REQUIRED", requests: ["security-team"])
  #expect(MergeBox.reviews(required) == MergeBoxLine(verdict: "Review required", detail: "security-team waiting", tone: .warn))
}

@Test func mergeBoxCheckLine() {
  let mixed = details(checks: [
    check("unit tests", conclusion: "FAILURE"), check("lint", status: "IN_PROGRESS"), check("build", conclusion: "SUCCESS"),
  ])
  #expect(MergeBox.checks(mixed) == MergeBoxLine(
    verdict: "1 check failing", detail: "unit tests · lint running · build passed", tone: .bad))
  let running = details(checks: [check("a", status: "IN_PROGRESS"), check("b", status: "QUEUED")])
  #expect(MergeBox.checks(running) == MergeBoxLine(verdict: "2 checks running", detail: "a running · b running", tone: .warn))
  let green = details(checks: [check("a", conclusion: "SUCCESS"), check("b", conclusion: "SUCCESS"), check("c", conclusion: "SUCCESS")])
  #expect(MergeBox.checks(green) == MergeBoxLine(verdict: "All checks passed", detail: "3 passed", tone: .good))
  let many = details(checks: [check("x", conclusion: "FAILURE"), check("y", conclusion: "FAILURE")]
    + (1...5).map { check("ok\($0)", conclusion: "SUCCESS") } + [check("slow", status: "IN_PROGRESS")])
  #expect(MergeBox.checks(many) == MergeBoxLine(verdict: "2 checks failing", detail: "x · y · 1 running · 5 passed", tone: .bad))
}

@Test func mergeBoxConflictLine() {
  #expect(MergeBox.conflicts(details()) == MergeBoxLine(verdict: "No conflicts", detail: "with main", tone: .good))
  #expect(MergeBox.conflicts(details(mergeable: "CONFLICTING")) == MergeBoxLine(verdict: "Conflicts", detail: "with main", tone: .bad))
  #expect(MergeBox.conflicts(details(mergeable: "UNKNOWN")) == MergeBoxLine(verdict: "Checking…", detail: "", tone: .muted))
}

@Test func mergeBoxEdgeCases() {
  #expect(MergeBox.checks(details()) == MergeBoxLine(verdict: "No checks", detail: "", tone: .muted))
  #expect(MergeBox.reviews(details()) == MergeBoxLine(verdict: "No reviews yet", detail: "", tone: .muted))
  #expect(MergeBox.reviews(details(requests: ["lead"])) == MergeBoxLine(verdict: "Review requested", detail: "lead waiting", tone: .warn))
  #expect(MergeBox.finished(details()) == nil)
  #expect(MergeBox.finished(details(state: "MERGED")) == MergeBoxLine(verdict: "Merged into main", detail: "", tone: .merged))
  #expect(MergeBox.finished(details(state: "CLOSED")) == MergeBoxLine(verdict: "Closed without merging", detail: "", tone: .muted))
  #expect(MergeBox.author(details(author: nil)) == "ghost")
  #expect(MergeBox.author(details()) == "octo")
}

@Test func checkDurationsAndRerunTargets() {
  #expect(PullRequests.durationLabel(8) == "8s")
  #expect(PullRequests.durationLabel(72) == "1m 12s")
  #expect(PullRequests.durationLabel(120) == "2m")
  #expect(PullRequests.durationLabel(3_780) == "1h 3m")
  var timed = check("t", conclusion: "SUCCESS")
  timed.startedAt = "2026-11-06T08:00:00Z"
  timed.completedAt = "2026-11-06T08:01:12Z"
  #expect(timed.duration == 72)
  #expect(check("t").duration == nil)
  let job = PullRequests.actionsRun("https://github.com/me/app/actions/runs/123/job/456")
  #expect(job?.nameWithOwner == "me/app" && job?.runID == "123")
  let run = PullRequests.actionsRun("https://github.com/me/app/actions/runs/123")
  #expect(run?.nameWithOwner == "me/app" && run?.runID == "123")
  #expect(PullRequests.actionsRun("https://ci.example.com/build/9") == nil)
}

@Test func mergeButtonStates() {
  let both = MergeSettings(methods: [.squash, .merge], autoMerge: true)
  let clean = details(status: "CLEAN")
  #expect(MergeBox.button(clean, settings: nil, lastMethod: nil) == .disabled("Loading merge options…"))
  // A remembered method the repository doesn't allow isn't used.
  #expect(MergeBox.button(clean, settings: both, lastMethod: .rebase) == .merge(.squash))
  #expect(MergeBox.button(clean, settings: both, lastMethod: .merge) == .merge(.merge))
  #expect(MergeBox.button(details(decision: "REVIEW_REQUIRED"), settings: both, lastMethod: nil) == .autoMerge(.squash))
  let noAuto = MergeSettings(methods: [.squash], autoMerge: false)
  #expect(
    MergeBox.button(details(decision: "REVIEW_REQUIRED"), settings: noAuto, lastMethod: nil)
      == .disabled("Blocked: review required — and auto-merge is off for this repo"))
  #expect(MergeBox.button(details(mergeable: "CONFLICTING"), settings: both, lastMethod: nil) == .disabled("Merge conflicts with main"))
  #expect(MergeBox.button(details(draft: true), settings: both, lastMethod: nil) == .disabled("Draft — not ready for review"))
  #expect(MergeBox.button(clean, settings: MergeSettings(methods: [], autoMerge: false), lastMethod: nil)
    == .disabled("The repository allows no merge method"))
}

@Test func reviewReviewFixes() {
  // gh writes Go's zero time for a check that hasn't finished.
  var running = check("t", status: "IN_PROGRESS")
  running.startedAt = "2026-11-06T08:00:00Z"
  running.completedAt = "0001-01-01T00:00:00Z"
  #expect(running.duration == nil)
  var queued = check("t", status: "QUEUED")
  queued.startedAt = "0001-01-01T00:00:00Z"
  queued.completedAt = "0001-01-01T00:00:00Z"
  #expect(queued.duration == nil)
  // Asked again after requesting changes: listed once, as waiting.
  let again = details(decision: "CHANGES_REQUESTED", reviews: [review("lead", "CHANGES_REQUESTED")], requests: ["lead"])
  #expect(MergeBox.reviews(again).detail == "lead waiting")
  // Only skipped checks: no "0 passed".
  let skipped = details(checks: [check("a", conclusion: "SKIPPED"), check("b", conclusion: "NEUTRAL")])
  #expect(MergeBox.checks(skipped) == MergeBoxLine(verdict: "All checks passed", detail: "2 skipped", tone: .good))
}
