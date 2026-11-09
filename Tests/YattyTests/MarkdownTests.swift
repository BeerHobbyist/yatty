import Foundation
import Testing

@testable import Yatty

private func texts(_ blocks: [MarkdownBlock]) -> [String] {
  blocks.map { String($0.text.characters) }
}

@Test func markdownKeepsGitHubsBlocks() {
  let blocks = MarkdownBlock.parse(
    """
    ## Summary
    Some **bold** text.

    - one
      1. nested
    - [ ] todo
    - [x] done

    > quoted

    ```swift
    let x = Array<Int>()
    ```

    ---
    """)
  #expect(texts(blocks) == ["Summary", "Some bold text.", "one", "nested", "todo", "done", "quoted", "let x = Array<Int>()", ""])
  #expect(blocks[0].kind == .heading(2))
  #expect(blocks.map(\.marker) == [nil, nil, "•", "1.", "☐", "☑", nil, nil, nil])
  #expect(blocks.map(\.lists) == [0, 0, 1, 2, 1, 1, 0, 0, 0])
  #expect(blocks[6].quoted)
  #expect(blocks[7].kind == .code)
  #expect(blocks[8].kind == .rule)
}

@Test func markdownBreaksLinesLikeAComment() {
  // A comment's single newline is a line break on GitHub; so is <br>.
  let blocks = MarkdownBlock.parse("first\nsecond<br>third <b>bold</b>")
  #expect(texts(blocks) == ["first\nsecond\nthird bold"])
}

@Test func markdownDropsHTMLButKeepsItsText() {
  let blocks = MarkdownBlock.parse(
    """
    <!-- a bot's note
    over two lines -->
    <details><summary>More</summary>

    Inside
    </details>
    """)
  #expect(texts(blocks) == ["More", "Inside"])
}

@Test func markdownTablesKeepEveryCellInItsColumn() {
  let blocks = MarkdownBlock.parse("| a | b |\n|---|---|\n| 1 | **2** |\n|   | 4 |\n|   |   |\n| 5 |   |")
  guard case .table(let rows) = blocks.first?.kind else {
    Issue.record("not a table: \(blocks)")
    return
  }
  #expect(rows.map { $0.map { String($0.characters) } } == [["a", "b"], ["1", "2"], ["", "4"], ["", ""], ["5", ""]])
}

@Test func markdownDropsHTMLInListsAndQuotes() {
  let blocks = MarkdownBlock.parse("- <img src=\"x.png\">\n\n  caption\n- two\n\n> <!-- note -->\n> quoted")
  #expect(texts(blocks) == ["caption", "two", "quoted"])
  // The item's marker moves to its first block with text.
  #expect(blocks.map(\.marker) == ["•", "•", nil])
  #expect(blocks[2].quoted)
}

@Test func reviewThreadsReadGraphQL() throws {
  let json = """
    {"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
      {"id":"T1","isResolved":true,"isOutdated":false,"path":"a.swift","line":null,"originalLine":7,
       "startLine":null,"originalStartLine":5,"diffSide":"LEFT","startDiffSide":"LEFT",
       "comments":{"nodes":[{"author":{"login":"lead"},"body":"Fix","createdAt":"2026-11-01T10:00:00Z","url":"u1"},
                            {"author":null,"body":"Done","createdAt":"2026-11-02T10:00:00Z","url":null}]}}
    ,{"id":"T2","isResolved":false,"isOutdated":false,"path":"b.swift","line":45,"originalLine":45,
       "startLine":50,"originalStartLine":50,"diffSide":"RIGHT","startDiffSide":"LEFT","comments":{"nodes":[]}}
    ]}}}}}
    """
  let threads = try #require(ReviewThread.parse(Data(json.utf8)))
  #expect(threads.count == 2)
  // From removed lines into added ones: only the end, whose number is the head's.
  #expect(threads[1].location == "b.swift:45")
  #expect(threads[0].isResolved)
  #expect(threads[0].line == 7)
  #expect(threads[0].location == "a.swift:5-7")
  #expect(threads[0].onBase)
  #expect(threads[0].comments.map(\.author) == ["lead", "?"])
  #expect(threads[0].date == "2026-11-02T10:00:00Z")
  #expect(ReviewThread.parse(Data(#"{"errors":[{"message":"no"}]}"#.utf8)) == nil)
}
