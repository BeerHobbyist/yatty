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
  #expect(line { $0.status = GitStatus() } == "up to date")
  // Not read yet (or unreadable): nothing is claimed.
  #expect(line { _ in } == "checking…")
  // The main working copy can't be closed: no "ready to close" there.
  #expect(
    line {
      var p = pr
      p.merged = true
      $0.pullRequest = p
      $0.isMain = true
    } == "merged")
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
  // Dropped onto another, a project takes its place, from either side.
  #expect(AppStore.moved(["/a", "/b", "/c"], "/c", onto: "/a") == ["/c", "/a", "/b"])
  #expect(AppStore.moved(["/a", "/b", "/c"], "/a", onto: "/c") == ["/b", "/c", "/a"])
  #expect(AppStore.moved(["/a", "/b", "/c"], "/a", onto: "/b") == ["/b", "/a", "/c"])
  #expect(AppStore.moved(["/a", "/b"], "/a", onto: "/a") == nil)
  #expect(AppStore.moved(["/a", "/b"], "/a", onto: "ssh:h1") == nil)
  #expect(AppStore.moved(["/a", "/b"], "/nope", onto: "/a") == nil)
  // One step up or down, not past the ends.
  #expect(AppStore.shifted(["/a", "/b", "/c"], "/b", by: -1) == ["/b", "/a", "/c"])
  #expect(AppStore.shifted(["/a", "/b", "/c"], "/b", by: 1) == ["/a", "/c", "/b"])
  #expect(AppStore.shifted(["/a", "/b"], "/a", by: -1) == nil)
  #expect(AppStore.shifted(["/a", "/b"], "/b", by: 1) == nil)
}

@Test func sidebarSelectionMapsNeedsYouRows() {
  #expect(SidebarSelection.tag("/r/a", inNeedsYou: true) == "needs-you:/r/a")
  #expect(SidebarSelection.tag("/r/a", inNeedsYou: false) == "/r/a")
  #expect(SidebarSelection.worktreeID(fromTag: "needs-you:/r/a") == "/r/a")
  #expect(SidebarSelection.worktreeID(fromTag: "/r/a") == "/r/a")
  #expect(SidebarSelection.isNeedsYou("needs-you:ssh:devbox:/x"))
  #expect(!SidebarSelection.isNeedsYou("ssh:devbox:/x"))
}

@Test func renameRules() {
  #expect(AppStore.cleanLabel("", automatic: "login") == nil)
  #expect(AppStore.cleanLabel("  \n", automatic: "login") == nil)
  #expect(AppStore.cleanLabel("  api ", automatic: "login") == "api")
  // The automatic name typed back (⏎ on an unedited field): still automatic.
  #expect(AppStore.cleanLabel(" login", automatic: "login") == nil)
}
