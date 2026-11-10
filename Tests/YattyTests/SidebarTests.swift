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

@Test func activeAgentsFloatUpByState() {
  let t = Date(timeIntervalSince1970: 1_000)
  let sections = WorktreeSummary.activeSections([
    ("idle", .idle, t),
    ("w2", .working, t),
    ("n1", .needsAction, t),
    ("d1", .done, t),
    ("w1", .working, t.addingTimeInterval(-60)),
    ("n2", .needsAction, t.addingTimeInterval(-30)),
    ("n3", .needsAction, t),
  ])
  // Needs you, then working, then done; idle stays in its project. Longest
  // in its state first; ties keep their order.
  #expect(sections.map(\.state) == [.needsAction, .working, .done])
  #expect(sections.map(\.ids) == [["n2", "n1", "n3"], ["w1", "w2"], ["d1"]])
  #expect(WorktreeSummary.activeSections([("a", .idle, t)]).isEmpty)
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

@Test func renameRules() {
  #expect(AppStore.cleanLabel("", automatic: "login") == nil)
  #expect(AppStore.cleanLabel("  \n", automatic: "login") == nil)
  #expect(AppStore.cleanLabel("  api ", automatic: "login") == "api")
  // The automatic name typed back (⏎ on an unedited field): still automatic.
  #expect(AppStore.cleanLabel(" login", automatic: "login") == nil)
}

@Test func agentsAreOrderedByWhenTheyEnteredTheirState() {
  let a = PaneKey(worktree: "/a", pane: "0"), b = PaneKey(worktree: "/b", pane: "0"), c = PaneKey(worktree: "/c", pane: "0")
  let entered = AgentMonitor.enteredTimes(
    old: [a: 100, b: 200],
    oldStates: [a: .working, b: .needsAction],
    newStates: [a: .working, b: .working, c: .done],
    reportedAt: [a: 900, b: 950, c: 50],
    now: 1_000)
  // Still working: its time stays, however often the report is rewritten.
  #expect(entered[a] == 100)
  // Changed state: from now.
  #expect(entered[b] == 1_000)
  // First seen: from its report.
  #expect(entered[c] == 50)
  #expect(entered.count == 3)
}

@Test func onlyFreshFinishesFloat() {
  #expect(AgentMonitor.floats(.needsAction, reportedAt: 10, launchedAt: 100))
  #expect(AgentMonitor.floats(.working, reportedAt: 10, launchedAt: 100))
  #expect(AgentMonitor.floats(.done, reportedAt: 150, launchedAt: 100))
  // Finished before Yatty started: seen or not, it stays in its project.
  #expect(!AgentMonitor.floats(.done, reportedAt: 50, launchedAt: 100))
  #expect(!AgentMonitor.floats(.idle, reportedAt: 150, launchedAt: 100))
}

@Test func sidebarOrderPutsFloatedRowsFirst() {
  let active: [(state: AgentState, ids: [String])] = [(.needsAction, ["/b"]), (.done, ["/c"])]
  #expect(WorktreeSummary.sidebarOrder(["/a", "/b", "/c", "/d"], active: active) == ["/b", "/c", "/a", "/d"])
}

@Test func theSelectedWorktreeStaysInItsSection() {
  let t = Date(timeIntervalSince1970: 1_000)
  let held = HeldFloat(id: "s", state: .done, since: t.addingTimeInterval(-10))
  // Seen and gone idle: still under Done, where it was, until deselected.
  #expect(WorktreeSummary.activeSections([("d", .done, t)], held: held).map(\.ids) == [["s", "d"]])
  // Its agent moved on (a prompt): it doesn't jump sections under the user.
  let moved = WorktreeSummary.activeSections([("s", .needsAction, t), ("n", .needsAction, t)], held: held)
  #expect(moved.map(\.state) == [.needsAction, .done])
  #expect(moved.map(\.ids) == [["n"], ["s"]])
  #expect(WorktreeSummary.activeSections([("d", .done, t)], held: nil).map(\.ids) == [["d"]])
}

@Test func theRowsIconIsItsPullRequestsState() {
  let pr = BranchPullRequest(number: 42, title: "", url: "", isDraft: false, merged: false, checks: .pass, headOid: "")
  func icon(main: Bool = false, remote: Bool = false, _ change: ((inout BranchPullRequest) -> Void)? = nil) -> WorktreeIcon {
    WorktreeIcon.of(isMain: main, isRemote: remote, pullRequest: change.map { change in
      var p = pr
      change(&p)
      return p
    })
  }
  // No pull request: what the worktree is.
  #expect(icon() == WorktreeIcon(name: .gitBranch, tint: .accent))
  #expect(icon(main: true) == WorktreeIcon(name: .home, tint: .accent))
  #expect(icon(remote: true) == WorktreeIcon(name: .fileDirectory, tint: .accent))
  // One: GitHub's icon for it, coloured by its checks.
  #expect(icon { _ in } == WorktreeIcon(name: .gitPullRequest, tint: .green))
  #expect(icon { $0.checks = .fail } == WorktreeIcon(name: .gitPullRequest, tint: .red))
  #expect(icon { $0.checks = .pending } == WorktreeIcon(name: .gitPullRequest, tint: .orange))
  #expect(icon { $0.checks = .skipped } == WorktreeIcon(name: .gitPullRequest, tint: .secondary))
  #expect(icon { $0.checks = nil } == WorktreeIcon(name: .gitPullRequest, tint: .secondary))
  #expect(icon { $0.isDraft = true; $0.checks = .fail } == WorktreeIcon(name: .gitPullRequestDraft, tint: .red))
  #expect(icon { $0.merged = true; $0.checks = .fail } == WorktreeIcon(name: .gitMerge, tint: .purple))
  #expect(icon(main: true) { $0.merged = true } == WorktreeIcon(name: .gitMerge, tint: .purple))
}
