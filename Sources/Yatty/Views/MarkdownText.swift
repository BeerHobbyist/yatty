import SwiftUI

/// Markdown as GitHub shows a comment: headings, lists, task lists, quotes,
/// code blocks, tables and links, and a single newline breaks the line. HTML
/// tags are dropped and the text in them kept; `<br>` breaks the line.
struct MarkdownText: View {
  let blocks: [MarkdownBlock]
  /// Height shown until "Show more"; nil shows it all.
  let maxHeight: CGFloat?
  @State private var expanded = false
  @State private var height: CGFloat = 0

  init(_ source: String, maxHeight: CGFloat? = nil) {
    self.init(blocks: MarkdownBlock.parse(source), maxHeight: maxHeight)
  }

  init(blocks: [MarkdownBlock], maxHeight: CGFloat? = nil) {
    self.blocks = blocks
    self.maxHeight = maxHeight
  }

  var body: some View {
    let overflows = maxHeight.map { height > $0 } ?? false
    VStack(alignment: .leading, spacing: 4) {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(blocks.indices, id: \.self) { MarkdownBlockView(block: blocks[$0]) }
      }
      .fixedSize(horizontal: false, vertical: true)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
      .frame(maxHeight: overflows && !expanded ? maxHeight : nil, alignment: .top)
      .clipped()
      if overflows {
        Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
          .buttonStyle(.link)
          .font(.caption)
      }
    }
    .textSelection(.enabled)
  }
}

/// One block of a parsed comment, with the lists and quotes it sits in.
struct MarkdownBlock: Equatable {
  enum Kind: Equatable {
    case paragraph
    case heading(Int)
    case code
    case rule
    /// Rows of cells, the header row first.
    case table([[AttributedString]])
  }

  var kind: Kind
  var text = AttributedString()
  /// How deep in lists it is.
  var lists = 0
  var quoted = false
  /// `•`, `3.`, `☐` or `☑` on a list item's first block.
  var marker: String?

  static func parse(_ source: String) -> [MarkdownBlock] {
    guard
      let parsed = try? AttributedString(
        markdown: source,
        options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible))
    else { return [MarkdownBlock(kind: .paragraph, text: AttributedString(source))] }

    var blocks: [MarkdownBlock] = []
    // The block the last run went into: its leaf block's or table's identity,
    // or for raw HTML, -1 minus its container's.
    var current: Int?
    var markedItems: Set<Int> = []

    for run in parsed.runs {
      let components = run.presentationIntent?.components ?? []
      let slice = AttributedString(parsed[run.range])

      // Raw HTML, alone or in a list or quote: its text, without tags or comments.
      if components.isEmpty || run.inlinePresentationIntent?.contains(.blockHTML) == true {
        let key = -1 - (components.first?.identity ?? 0)
        if current != key {
          var block = MarkdownBlock(kind: .paragraph)
          block.place(in: components, markedItems: &markedItems)
          blocks.append(block)
          current = key
        }
        blocks[blocks.count - 1].text += AttributedString(stripHTML(String(slice.characters)))
        continue
      }
      let leaf = components[0]

      if case .tableCell(let column) = leaf.kind,
        let table = components.first(where: { if case .table = $0.kind { true } else { false } }),
        case .table(let columns) = table.kind
      {
        if current != table.identity {
          var block = MarkdownBlock(kind: .table([]))
          block.place(in: components, markedItems: &markedItems)
          blocks.append(block)
          current = table.identity
        }
        guard case .table(var rows) = blocks[blocks.count - 1].kind else { continue }
        // By index: an empty cell, or row, has no run of its own.
        let rowIndex =
          components.lazy.compactMap { component -> Int? in
            switch component.kind {
            case .tableHeaderRow: 0
            case .tableRow(let index): index
            default: nil
            }
          }.first ?? rows.count
        while rows.count <= rowIndex { rows.append(Array(repeating: AttributedString(), count: columns.count)) }
        if column < columns.count { rows[rowIndex][column] += inline(slice, run: run) }
        blocks[blocks.count - 1].kind = .table(rows)
        continue
      }

      if current != leaf.identity {
        let kind: Kind =
          switch leaf.kind {
          case .header(let level): .heading(level)
          case .codeBlock: .code
          case .thematicBreak: .rule
          default: .paragraph
          }
        var block = MarkdownBlock(kind: kind)
        block.place(in: components, markedItems: &markedItems)
        blocks.append(block)
        current = leaf.identity
      }
      if blocks[blocks.count - 1].kind == .rule { continue }
      blocks[blocks.count - 1].text += inline(slice, run: run)
    }

    // Blocks left empty (HTML with no text) go; a list item's marker moves
    // on to the item's next block.
    var kept: [MarkdownBlock] = []
    var orphanMarker: (marker: String, lists: Int)?
    for var block in blocks {
      block.tidy()
      if block.isEmpty {
        if let marker = block.marker { orphanMarker = (marker, block.lists) }
        continue
      }
      if block.marker == nil, let orphan = orphanMarker, orphan.lists == block.lists { block.marker = orphan.marker }
      orphanMarker = nil
      kept.append(block)
    }
    return kept
  }

  private var isEmpty: Bool {
    switch kind {
    case .paragraph, .heading, .code: text.characters.isEmpty
    case .rule, .table: false
    }
  }

  /// Its depth in lists, whether it's quoted, and the marker of the list
  /// item it starts.
  private mutating func place(in components: [PresentationIntent.IntentType], markedItems: inout Set<Int>) {
    for (index, component) in components.enumerated() {
      switch component.kind {
      case .orderedList, .unorderedList: lists += 1
      case .blockQuote: quoted = true
      case .listItem(let ordinal):
        // Only the innermost item's first block gets its marker.
        guard marker == nil, lists == 0, !markedItems.contains(component.identity) else { continue }
        markedItems.insert(component.identity)
        let ordered = components.dropFirst(index + 1).first.map { $0.kind == .orderedList } ?? false
        marker = ordered ? "\(ordinal)." : "•"
      default: break
      }
    }
  }

  /// A run as text: GitHub's line breaks, HTML tags dropped, images as links.
  private static func inline(_ slice: AttributedString, run: AttributedString.Runs.Run) -> AttributedString {
    let intent = run.inlinePresentationIntent ?? []
    if intent.contains(.softBreak) { return AttributedString("\n") }
    if intent.contains(.inlineHTML) {
      let tag = String(slice.characters).lowercased().replacingOccurrences(of: " ", with: "")
      return tag.hasPrefix("<br") ? AttributedString("\n") : AttributedString()
    }
    var text = slice
    if let image = run.imageURL { text.link = image }
    return text
  }

  static func stripHTML(_ html: String) -> String {
    html
      .replacingOccurrences(of: "<!--[\\s\\S]*?(-->|$)", with: "", options: .regularExpression)
      .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
      .replacingOccurrences(of: "</?[a-zA-Z][^>]*>", with: "", options: .regularExpression)
  }

  /// Trims what the parser leaves at the edges, and turns `[ ]`/`[x]` into
  /// a task list's boxes.
  private mutating func tidy() {
    while let last = text.characters.last, last.isNewline || (kind == .paragraph && last.isWhitespace) {
      text.characters.removeLast()
    }
    while kind == .paragraph, let first = text.characters.first, first.isWhitespace {
      text.characters.removeFirst()
    }
    guard marker == "•" else { return }
    let start = String(text.characters.prefix(4))
    if start == "[ ] " || start == "[x] " || start == "[X] " {
      marker = start == "[ ] " ? "☐" : "☑"
      text.removeSubrange(text.startIndex..<text.index(text.startIndex, offsetByCharacters: 4))
    }
  }
}

private struct MarkdownBlockView: View {
  let block: MarkdownBlock

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      if block.lists > 0 {
        Text(block.marker ?? "").foregroundStyle(.secondary).frame(width: 16, alignment: .trailing)
      }
      content
    }
    .padding(.leading, CGFloat(max(block.lists - 1, 0)) * 20)
    .padding(.leading, block.quoted ? 10 : 0)
    .overlay(alignment: .leading) {
      if block.quoted { Rectangle().fill(.quaternary).frame(width: 3) }
    }
    .opacity(block.quoted ? 0.75 : 1)
  }

  @ViewBuilder private var content: some View {
    switch block.kind {
    case .paragraph:
      Text(block.text)
    case .heading(let level):
      Text(block.text).font(level == 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
    case .code:
      Text(block.text)
        .font(.callout.monospaced())
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    case .rule:
      Divider()
    case .table(let rows):
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
        ForEach(rows.indices, id: \.self) { index in
          GridRow {
            ForEach(rows[index].indices, id: \.self) { column in
              Text(rows[index][column]).fontWeight(index == 0 ? .semibold : nil)
            }
          }
          if index == 0 { Divider() }
        }
      }
    }
  }
}
