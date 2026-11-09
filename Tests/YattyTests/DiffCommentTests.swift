import Foundation
import Testing

@testable import Yatty

@Test func diffFilesAreReadInOrder() {
  let diff = """
    diff --git a/Sources/App.swift b/Sources/App.swift
    index 1..2 100644
    --- a/Sources/App.swift
    +++ b/Sources/App.swift
    @@ -1 +1 @@
    -a
    +b
    diff --git a/new file.txt b/new file.txt
    new file mode 100644
    --- /dev/null
    +++ b/new file.txt
    @@ -0,0 +1 @@
    +hi
    diff --git a/gone.txt b/gone.txt
    deleted file mode 100644
    --- a/gone.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -bye
    diff --git a/old.swift b/renamed.swift
    similarity index 100%
    rename from old.swift
    rename to renamed.swift
    diff --git a/logo.png b/logo.png
    Binary files a/logo.png and b/logo.png differ

    """
  #expect(UnifiedDiff.files(diff) == ["Sources/App.swift", "new file.txt", "gone.txt", "renamed.swift", "logo.png"])
  #expect(UnifiedDiff.files("") == [])
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
}

@Test func localReviewPromptSaysItsYours() {
  let comments = [
    DiffComment(id: "2", path: "b.swift", line: 9, side: .old, code: "oldCall()", text: "Why remove this?"),
    DiffComment(id: "1", path: "a.swift", line: 12, side: .new, code: "let ttl = 15 * 60", text: "Make it configurable."),
    DiffComment(id: "3", path: "a.swift", line: 4, side: .new, code: "", text: "Typo above."),
  ]
  let prompt = LocalReviewPrompt.make(target: .working, branch: "feature/login", comments: comments)
  #expect(prompt.contains("my own review of the working changes in this worktree (feature/login)"))
  #expect(prompt.contains("not comments from GitHub"))
  let order = ["## 1. `a.swift:4`", "## 2. `a.swift:12`", "## 3. `b.swift:9` (a removed line)"]
  let positions = order.map { prompt.range(of: $0)?.lowerBound }
  #expect(positions.allSatisfy { $0 != nil })
  #expect(positions.compactMap { $0 } == positions.compactMap { $0 }.sorted())
  #expect(prompt.contains("```\nlet ttl = 15 * 60\n```\nMake it configurable."))
  #expect(LocalReviewPrompt.make(target: .base("origin/main"), branch: nil, comments: comments).contains("of the changes vs origin/main"))
}
