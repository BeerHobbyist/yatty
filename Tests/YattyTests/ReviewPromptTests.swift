import Foundation
import Testing

@testable import Yatty

private let details = PullRequestDetails(
  number: 42, title: "Login with magic links", url: "https://github.com/me/app/pull/42", state: "OPEN",
  isDraft: false, author: .init(login: "octo"), baseRefName: "main", headRefName: "feature/login", headRefOid: "h",
  additions: 1, deletions: 0, changedFiles: 1, updatedAt: "", mergeable: "MERGEABLE", mergeStateStatus: "CLEAN",
  reviewDecision: "", latestReviews: [], reviewRequests: [],
  reviews: [.init(author: .init(login: "lead"), state: "CHANGES_REQUESTED", submittedAt: "2026-11-06T08:00:00Z", body: "Needs a test.")],
  comments: [
    .init(author: .init(login: "octo"), body: "Ready again.", createdAt: "2026-11-06T09:30:00Z", url: "c1"),
    .init(author: .init(login: "bot"), body: "Coverage 80%<!-- meta -->", createdAt: "2026-11-06T07:00:00Z", url: "c2"),
  ],
  labels: [], statusCheckRollup: [], body: "")

private func thread(
  _ id: String, path: String, line: Int?, resolved: Bool, outdated: Bool = false, onBase: Bool = false
) -> ReviewThread {
  ReviewThread(
    id: id, path: path, line: line, onBase: onBase, isResolved: resolved, isOutdated: outdated,
    comments: [
      .init(author: "lead", body: "Why \(id)?", createdAt: "2026-11-06T08:10:00Z", url: nil),
      .init(author: "octo", body: "Because.", createdAt: "2026-11-06T08:20:00Z", url: nil),
    ])
}

@Test func conversationsAreNewestFirstAndPickWhatsOpenFromOthers() {
  let items = PullRequestConversation.all(
    details: details, threads: [thread("T1", path: "b.swift", line: 3, resolved: false), thread("T2", path: "a.swift", line: 9, resolved: true)])
  #expect(items.map(\.id) == ["c1", "T1", "T2", "review-0-2026-11-06T08:00:00Z", "c2"])
  let picked = items.filter { $0.pickedByDefault(author: "octo") }.map(\.id)
  // Not the resolved thread, not the author's own comment.
  #expect(picked == ["T1", "review-0-2026-11-06T08:00:00Z", "c2"])
}

@Test func reviewPromptSaysItsFromGitHub() {
  let items = PullRequestConversation.all(
    details: details,
    threads: [
      thread("T1", path: "b.swift", line: 3, resolved: false, onBase: true),
      thread("T2", path: "a.swift", line: 9, resolved: true, outdated: true),
    ])
  let prompt = ReviewPrompt.make(details: details, picked: items.filter { $0.id != "c1" })
  #expect(prompt.contains("review of pull request #42 \"Login with magic links\" on GitHub (https://github.com/me/app/pull/42)"))
  #expect(prompt.contains("they are not from a local review of mine"))
  // Threads first, by file; then the rest, oldest first.
  let order = ["## 1. Thread on `a.swift:9` (resolved on GitHub; outdated: the code has changed since)",
               "## 2. Thread on `b.swift:3` (unresolved; on removed lines: the numbers are the base branch's)",
               "## 3. Comment by bot", "## 4. Review by lead (changes requested)"]
  let positions = order.map { prompt.range(of: $0)?.lowerBound }
  #expect(positions.allSatisfy { $0 != nil })
  #expect(positions.compactMap { $0 } == positions.compactMap { $0 }.sorted())
  #expect(prompt.contains("**octo**, the pull request's author on 2026-11-06:\nBecause."))
  #expect(prompt.contains("Coverage 80%"))
  #expect(!prompt.contains("meta"))
  #expect(!prompt.contains("Ready again."))
}
