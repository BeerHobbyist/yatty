import Foundation
import Testing

@testable import Yatty

@Test func commentsFollowTheirLines() {
  var tab = DiffTab(target: .working, comments: [
    DiffComment(id: "c1", path: "a.swift", line: 2, side: .new, code: "let two = 22", text: "Why 22?"),
    DiffComment(id: "c2", path: "a.swift", line: 5, side: .new, code: "gone()", text: "Hm"),
  ])
  // The page found c1's line two lines down, and c2's nowhere.
  let anchors = [
    DiffComment.Anchor(id: "c1", line: 4, outdated: false), DiffComment.Anchor(id: "c2", line: 5, outdated: true),
    DiffComment.Anchor(id: "unknown", line: 1, outdated: true),
  ]
  let moved = tab.place(anchors)
  #expect(moved)
  #expect(tab.comments.map(\.line) == [4, 5])
  #expect(tab.comments.map(\.outdated) == [false, true])
  // Told again, nothing changes (so nothing is saved again).
  let again = tab.place(anchors)
  #expect(!again)
  // Back in the diff: no longer outdated.
  let back = tab.place([DiffComment.Anchor(id: "c2", line: 7, outdated: false)])
  #expect(back)
  #expect(tab.comments[1].line == 7 && !tab.comments[1].outdated)
}

@Test func diffTabsKeepTheirComments() throws {
  var layout = WorktreeLayout.initial
  layout.addDiffTab(pane: "d1", id: "td", target: .working)
  let comment = DiffComment(id: "c1", path: "a.swift", line: 3, side: .new, code: "let x = 1", text: "Name it")
  layout.updateDiff("td") { $0.comments.append(comment) }
  #expect(layout.diffTab(for: .working)?.diff?.comments == [comment])
  let decoded = try JSONDecoder().decode(WorktreeLayout.self, from: JSONEncoder().encode(layout))
  #expect(decoded.tabs.last?.diff?.comments == [comment])
  // A diff tab saved before comments existed still loads.
  let old = try JSONDecoder().decode(DiffTab.self, from: Data(#"{"target":{"working":{}}}"#.utf8))
  #expect(old.comments.isEmpty)
  // A comment saved before it could be outdated still loads.
  let saved = try JSONDecoder().decode(
    DiffComment.self, from: Data(#"{"id":"c","path":"p","line":1,"side":"new","code":"","text":"t"}"#.utf8))
  #expect(!saved.outdated)
}

@Test func localReviewPromptSaysItsYours() {
  let comments = [
    DiffComment(id: "2", path: "b.swift", line: 9, side: .old, code: "oldCall()", text: "Why remove this?"),
    DiffComment(id: "1", path: "a.swift", line: 12, side: .new, code: "let ttl = 15 * 60", text: "Make it configurable."),
    DiffComment(id: "3", path: "a.swift", line: 4, side: .new, code: "", text: "Typo above."),
    DiffComment(id: "4", path: "c.swift", line: 1, side: .new, code: "old()", text: "Still?", outdated: true),
  ]
  let prompt = LocalReviewPrompt.make(target: .working, branch: "feature/login", comments: comments)
  #expect(prompt.contains("my own review of the working changes in this worktree (feature/login)"))
  #expect(prompt.contains("not comments from GitHub"))
  let order = [
    "## 1. `a.swift:4`", "## 2. `a.swift:12`", "## 3. `b.swift:9` (a removed line)",
    "## 4. `c.swift:1` (the line has changed since)",
  ]
  let positions = order.map { prompt.range(of: $0)?.lowerBound }
  #expect(positions.allSatisfy { $0 != nil })
  #expect(positions.compactMap { $0 } == positions.compactMap { $0 }.sorted())
  #expect(prompt.contains("```\nlet ttl = 15 * 60\n```\nMake it configurable."))
  #expect(LocalReviewPrompt.make(target: .base("origin/main"), branch: nil, comments: comments).contains("of the changes vs origin/main"))
}
