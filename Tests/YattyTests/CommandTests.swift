import SwiftUI
import Testing

@testable import Yatty

@Test func matchingFollowsAgentree() {
  #expect(CommandMatch.score("new", "New Worktree…") == 100)
  #expect(CommandMatch.score("work", "New Worktree…") == 80)
  #expect(CommandMatch.score("tree", "New Worktree…") == 60)
  #expect(CommandMatch.score("nwt", "New Worktree…") == 20)
  #expect(CommandMatch.score("xyz", "New Worktree…") == 0)
  #expect(CommandMatch.score("  ", "anything") == 1)
  #expect(CommandMatch.score("NEW", "new tab") == 100)
}

@Test func filterRanksTitleOverGroup() {
  let commands = [
    Command(id: "a", title: "Merge Pull Request…", group: "Pull Request", run: {}),
    Command(id: "b", title: "Split Right", group: "Terminal", run: {}),
    Command(id: "c", title: "New Tab", group: "Terminal", run: {}),
    Command(id: "d", title: "Show Pull Request", group: "Pull Request", run: {}),
  ]
  #expect(CommandMatch.filter(commands, query: "").map(\.id) == ["a", "d", "b", "c"])
  // "pull" starts a word in two titles (80 × 2) and is the group's start (100).
  #expect(CommandMatch.filter(commands, query: "pull").map(\.id) == ["a", "d"])
  #expect(CommandMatch.filter(commands, query: "term").map(\.id) == ["b", "c"])
  #expect(CommandMatch.filter(commands, query: "split").map(\.id) == ["b"])
  #expect(CommandMatch.filter(commands, query: "zzz").isEmpty)
}

@Test func shortcutsLabelLikeMenus() {
  #expect(KeyboardShortcut("k").label == "⌘K")
  #expect(KeyboardShortcut("d", modifiers: [.command, .shift]).label == "⇧⌘D")
  #expect(KeyboardShortcut("=", modifiers: [.command, .control]).label == "⌃⌘=")
  #expect(KeyboardShortcut("t", modifiers: [.command, .option]).label == "⌥⌘T")
}
