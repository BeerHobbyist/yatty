import Foundation
import Testing

@testable import Yatty

@Test func secondLineTakesTheFirstFactThatApplies() {
  let now = Date(timeIntervalSince1970: 10_000)
  func line(_ change: (inout WorktreeFacts) -> Void) -> String {
    var facts = WorktreeFacts(
      agent: nil, waitingSince: nil, pullRequest: nil, status: nil, branch: "main", label: "main",
      remotePath: nil, disconnected: false)
    change(&facts)
    return WorktreeSummary.secondLine(facts, now: now)
  }
  let pr = BranchPullRequest(number: 194, title: "", url: "", isDraft: false, merged: false, checks: .fail, headOid: "")
  #expect(line { $0.agent = .needsAction; $0.waitingSince = now.addingTimeInterval(-720); $0.pullRequest = pr } == "waiting 12m")
  #expect(line { $0.agent = .needsAction; $0.waitingSince = now.addingTimeInterval(-20) } == "waiting <1m")
  #expect(line { $0.agent = .needsAction; $0.waitingSince = now.addingTimeInterval(-7_300) } == "waiting 2h")
  #expect(line { $0.agent = .needsAction; $0.waitingSince = now.addingTimeInterval(-200_000) } == "waiting 2d")
  #expect(line { $0.pullRequest = pr } == "PR #194 · checks failing")
  #expect(
    line {
      var p = pr
      p.checks = .pass
      p.reviewDecision = "CHANGES_REQUESTED"
      $0.pullRequest = p
    } == "PR #194 · changes requested")
  #expect(
    line {
      var p = pr
      p.merged = true
      $0.pullRequest = p
    } == "merged · ready to close")
  #expect(line { $0.agent = .working; $0.status = GitStatus(changed: 5) } == "working")
  #expect(line { $0.status = GitStatus(changed: 13, ahead: 2) } == "13 changes · ↑2")
  #expect(line { $0.status = GitStatus(changed: 2, ahead: 1, behind: 4) } == "2 changes · ↑1 · ↓4")
  #expect(line { $0.status = GitStatus(changed: 1) } == "1 change")
  #expect(line { $0.status = GitStatus(behind: 18) } == "↓18 behind")
  #expect(line { $0.status = GitStatus(ahead: 3) } == "↑3 ahead")
  #expect(line { $0.label = "login"; $0.branch = "feature/login" } == "feature/login")
  #expect(line { $0.remotePath = "devbox:~/src/api"; $0.branch = nil; $0.label = "api" } == "devbox:~/src/api")
  #expect(line { $0.remotePath = "devbox:~/src/api"; $0.disconnected = true } == "disconnected")
  #expect(line { _ in } == "up to date")
}

@Test func filterMatchesNameBranchOrProject() {
  #expect(WorktreeSummary.matches("", name: "x", branch: nil, project: "p"))
  #expect(WorktreeSummary.matches("   ", name: "x", branch: nil, project: "p"))
  #expect(WorktreeSummary.matches("  LOG ", name: "login", branch: nil, project: "p"))
  #expect(WorktreeSummary.matches("feature/", name: "login", branch: "feature/login", project: "p"))
  #expect(WorktreeSummary.matches("flutter", name: "main", branch: "main", project: "sap-flutter-framework"))
  #expect(!WorktreeSummary.matches("zzz", name: "login", branch: "feature/login", project: "p"))
}

@Test func needsYouLongestWaitFirst() {
  let t = Date(timeIntervalSince1970: 1_000)
  let order = WorktreeSummary.needsYouOrder([("a", t), ("b", t.addingTimeInterval(-60)), ("c", t.addingTimeInterval(30))])
  #expect(order == ["b", "a", "c"])
}

@Test func projectsMoveWithinTheirOwnList() {
  #expect(AppStore.moved(["/r1", "/r2", "/r3"], "/r3", before: "/r1") == ["/r3", "/r1", "/r2"])
  #expect(AppStore.moved(["/r1", "/r2", "/r3"], "/r1", before: "/r3") == ["/r2", "/r1", "/r3"])
  #expect(AppStore.moved(["/r1", "/r2"], "/r1", before: "/r1") == nil)
  #expect(AppStore.moved(["/r1", "/r2"], "/r1", before: "ssh:h1") == nil)
  #expect(AppStore.moved(["/r1", "/r2"], "/nope", before: "/r1") == nil)
}
