import Foundation
import Testing

@testable import Yatty

private func check(state: String? = nil, status: String? = nil, conclusion: String? = nil) -> RawCheck {
  RawCheck(state: state, status: status, conclusion: conclusion, name: "c", context: nil, detailsUrl: nil, targetUrl: nil)
}

@Test func checkStatesFollowRunAndStatus() {
  #expect(PullRequests.checkState(check(state: "SUCCESS")) == .pass)
  #expect(PullRequests.checkState(check(state: "ERROR")) == .fail)
  #expect(PullRequests.checkState(check(state: "EXPECTED")) == .pending)
  #expect(PullRequests.checkState(check(status: "IN_PROGRESS")) == .pending)
  #expect(PullRequests.checkState(check(status: "COMPLETED", conclusion: "SUCCESS")) == .pass)
  #expect(PullRequests.checkState(check(status: "COMPLETED", conclusion: "SKIPPED")) == .skipped)
  #expect(PullRequests.checkState(check(status: "COMPLETED", conclusion: "TIMED_OUT")) == .fail)
  #expect(PullRequests.checkState(check(status: "COMPLETED", conclusion: "STARTUP_FAILURE")) == .fail)
}

@Test func summaryPrefersFailures() {
  #expect(PullRequests.summarize([.pass, .fail, .pending]) == .fail)
  #expect(PullRequests.summarize([.pass, .pending]) == .pending)
  #expect(PullRequests.summarize([.skipped, .pass]) == .pass)
  #expect(PullRequests.summarize([.skipped]) == .skipped)
  #expect(PullRequests.summarize([]) == nil)
}

@Test func mergedPRMustBeThisBranchs() {
  // HEAD is the PR's head, one of its commits, or past its head — and the
  // merge isn't in the branch yet.
  #expect(PullRequests.isThisBranchs(head: "h", prHead: "h", prCommits: [], prHeadIsAncestorOfHead: false, mergeCommitIsAncestorOfHead: false))
  #expect(PullRequests.isThisBranchs(head: "c2", prHead: "h", prCommits: ["c1", "c2"], prHeadIsAncestorOfHead: false, mergeCommitIsAncestorOfHead: false))
  #expect(PullRequests.isThisBranchs(head: "x", prHead: "h", prCommits: [], prHeadIsAncestorOfHead: true, mergeCommitIsAncestorOfHead: false))
  // An older branch's PR with the same name: none of its commits.
  #expect(!PullRequests.isThisBranchs(head: "x", prHead: "h", prCommits: ["c1"], prHeadIsAncestorOfHead: false, mergeCommitIsAncestorOfHead: false))
  // A branch started from main after the merge: the merge is in it.
  #expect(!PullRequests.isThisBranchs(head: "x", prHead: "h", prCommits: [], prHeadIsAncestorOfHead: true, mergeCommitIsAncestorOfHead: true))
}

@Test func failedRefreshKeepsLastBadge() {
  let badge = BranchPullRequest(number: 4, title: "t", url: "u", isDraft: false, merged: false, checks: .pass, headOid: "h")
  struct Offline: Error {}
  #expect(PullRequestStore.apply(result: .failure(Offline()), to: .some(badge)) == .some(badge))
  #expect(PullRequestStore.apply(result: .success(nil), to: .some(badge)) == .some(nil))
  #expect(PullRequestStore.apply(result: .failure(Offline()), to: nil) == nil)
}

private func details(
  state: String = "OPEN", draft: Bool = false, mergeable: String = "MERGEABLE", status: String = "CLEAN",
  review: String = "", checks: [RawCheck] = []
) -> PullRequestDetails {
  PullRequestDetails(
    number: 1, title: "t", url: "u", state: state, isDraft: draft, author: .init(login: "a"),
    baseRefName: "main", headRefName: "x", headRefOid: "h", additions: 1, deletions: 0, changedFiles: 1,
    updatedAt: "", mergeable: mergeable, mergeStateStatus: status, reviewDecision: review,
    latestReviews: [], reviewRequests: [], reviews: [], comments: [], labels: [], statusCheckRollup: checks, body: "")
}

@Test func mergeStatusTable() {
  #expect(PullRequests.mergeStatus(details(state: "MERGED")).label == "Merged")
  #expect(PullRequests.mergeStatus(details(state: "CLOSED")).label == "Closed without merging")
  #expect(PullRequests.mergeStatus(details(draft: true)).label == "Draft — not ready for review")
  #expect(PullRequests.mergeStatus(details(mergeable: "CONFLICTING")).label == "Merge conflicts with main")
  #expect(PullRequests.mergeStatus(details(status: "BEHIND")).label == "Branch is behind main")
  #expect(PullRequests.mergeStatus(details(status: "BLOCKED", review: "CHANGES_REQUESTED")).label == "Blocked: changes requested")
  #expect(PullRequests.mergeStatus(details(status: "BLOCKED", review: "REVIEW_REQUIRED")).label == "Blocked: review required")
  #expect(PullRequests.mergeStatus(details(status: "BLOCKED", checks: [check(state: "FAILURE")])).label == "Blocked: failing checks")
  #expect(PullRequests.mergeStatus(details(status: "BLOCKED", checks: [check(status: "QUEUED")])).label == "Blocked: checks running")
  #expect(PullRequests.mergeStatus(details(status: "BLOCKED")).label == "Blocked by branch protection")
  #expect(PullRequests.mergeStatus(details(status: "UNSTABLE")).label == "Mergeable, but some checks failed")
  #expect(PullRequests.mergeStatus(details(status: "CLEAN")).label == "Ready to merge")
  #expect(PullRequests.mergeStatus(details(status: "UNKNOWN", checks: [check(status: "QUEUED")])).label == "Checks running")
  #expect(PullRequests.mergeStatus(details(status: "UNKNOWN")).label == "Checking mergeability…")
}

@Test func mergeSettingsWithoutPushAccess() {
  #expect(MergeSettings.decode([:]) == MergeSettings(methods: [.merge, .squash, .rebase], autoMerge: false))
  #expect(MergeSettings.decode(["allow_merge_commit": false, "allow_rebase_merge": false, "allow_auto_merge": true])
    == MergeSettings(methods: [.squash], autoMerge: true))
}

@Test func mergeOptionsPerState() {
  let auto = MergeSettings(methods: [.squash], autoMerge: true)
  let manual = MergeSettings(methods: [.squash], autoMerge: false)
  #expect(PullRequests.mergeOptions(details(status: "CLEAN"), settings: manual).now)
  #expect(PullRequests.mergeOptions(details(status: "UNSTABLE"), settings: manual).now)
  #expect(PullRequests.mergeOptions(details(status: "BLOCKED"), settings: auto).auto)
  let blocked = PullRequests.mergeOptions(details(status: "BLOCKED"), settings: manual)
  #expect(!blocked.now && !blocked.auto && blocked.reason?.contains("auto-merge is off") == true)
  #expect(PullRequests.mergeOptions(details(mergeable: "CONFLICTING"), settings: auto).reason == "Merge conflicts with main")
  #expect(!PullRequests.mergeOptions(details(state: "MERGED"), settings: auto).now)
  #expect(!PullRequests.mergeOptions(details(draft: true), settings: auto).now)
}

@Test func relativeTimeBuckets() {
  let now = ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z")!
  #expect(PullRequests.relativeTime("2026-11-06T11:59:40Z", now: now) == "just now")
  #expect(PullRequests.relativeTime("2026-11-06T11:55:00Z", now: now) == "5m ago")
  #expect(PullRequests.relativeTime("2026-11-06T09:00:00Z", now: now) == "3h ago")
  #expect(PullRequests.relativeTime("2026-11-04T12:00:00Z", now: now) == "2d ago")
  #expect(PullRequests.relativeTime("2026-08-01T12:00:00Z", now: now) == "2026-08-01")
  #expect(PullRequests.relativeTime("nonsense", now: now) == "")
}

@Test func detailsJSONDecodes() throws {
  let json = #"""
    {"number":42,"title":"Login","url":"https://github.com/o/r/pull/42","state":"OPEN","isDraft":false,
     "author":{"login":"octo","name":"Octo","is_bot":false},"baseRefName":"main","headRefName":"feature/login",
     "headRefOid":"abc","additions":10,"deletions":2,"changedFiles":3,"updatedAt":"2026-11-06T10:00:00Z",
     "mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","reviewDecision":"REVIEW_REQUIRED",
     "latestReviews":[{"author":{"login":"rev"},"state":"APPROVED","submittedAt":"2026-11-06T09:00:00Z","body":""}],
     "reviewRequests":[{"__typename":"User","login":"lead"},{"__typename":"Team","name":"core","slug":"core"}],
     "reviews":[{"author":{"login":"rev"},"state":"COMMENTED","submittedAt":"2026-11-06T08:00:00Z","body":"Looks fine"}],
     "comments":[{"author":{"login":"octo"},"body":"Ping","createdAt":"2026-11-06T07:00:00Z","url":"https://x"}],
     "labels":[{"name":"bug","color":"d73a4a","description":""}],
     "statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://c"},
                          {"__typename":"StatusContext","context":"ci/x","state":"PENDING","targetUrl":"https://t"}],
     "body":"Adds **login**."}
    """#
  let d = try JSONDecoder().decode(PullRequestDetails.self, from: Data(json.utf8))
  #expect(d.number == 42)
  #expect(d.reviewRequests.map(\.displayName) == ["lead", "core"])
  #expect(d.statusCheckRollup.map(PullRequests.checkState) == [.pass, .pending])
  #expect(d.labels.first?.name == "bug")
}
