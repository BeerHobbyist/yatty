import SwiftUI

/// One thing Yatty can do, as the command palette and the help window list
/// it: every action is findable by name, with the key that does it directly.
struct Command: Identifiable {
  let id: String
  let title: String
  /// What it acts on: the palette's groups, in the order they first appear.
  let group: String
  /// The menu's own key for it, if it has one.
  var shortcut: KeyboardShortcut?
  /// A word on what it'll do now: the PR it merges, the worktree it opens.
  var detail: String?
  let run: @MainActor () -> Void
}

/// agentree's command palette matching (src/components/CommandPalette.tsx).
enum CommandMatch {
  /// How well `query` matches `text` (0: not at all): all of it in one piece
  /// at the start beats at a word's start, which beats inside, which beats
  /// its letters in order.
  static func score(_ query: String, _ text: String) -> Int {
    let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    let t = text.lowercased()
    if q.isEmpty { return 1 }
    if let range = t.range(of: q) {
      if range.lowerBound == t.startIndex { return 100 }
      // agentree's `\W`: letters, digits and `_` continue a word.
      let before = t[t.index(before: range.lowerBound)]
      return before.isLetter || before.isNumber || before == "_" ? 60 : 80
    }
    var rest = Substring(q)
    for character in t where character == rest.first { rest = rest.dropFirst() }
    return rest.isEmpty ? 20 : 0
  }

  /// The commands matching `query`, best first, the title counting double
  /// against the group; all of them, grouped, when it's empty.
  static func filter(_ commands: [Command], query: String) -> [Command] {
    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      var order: [String] = []
      for command in commands where !order.contains(command.group) { order.append(command.group) }
      return commands.enumerated()
        .sorted { (order.firstIndex(of: $0.element.group)!, $0.offset) < (order.firstIndex(of: $1.element.group)!, $1.offset) }
        .map(\.element)
    }
    return commands.enumerated()
      .map { (command: $0.element, offset: $0.offset, score: max(score(query, $0.element.title) * 2, score(query, $0.element.group))) }
      .filter { $0.score > 0 }
      .sorted { ($0.score, -$0.offset) > ($1.score, -$1.offset) }
      .map(\.command)
  }
}

extension KeyboardShortcut {
  /// As macOS menus show it: ⌃⌥⇧⌘ then the key.
  var label: String {
    var text = ""
    if modifiers.contains(.control) { text += "⌃" }
    if modifiers.contains(.option) { text += "⌥" }
    if modifiers.contains(.shift) { text += "⇧" }
    if modifiers.contains(.command) { text += "⌘" }
    switch key {
    case .return: text += "↩"
    case .escape: text += "⎋"
    case .tab: text += "⇥"
    case .upArrow: text += "↑"
    case .downArrow: text += "↓"
    case .leftArrow: text += "←"
    case .rightArrow: text += "→"
    default: text += String(key.character).uppercased()
    }
    return text
  }
}
