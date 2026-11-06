import SwiftUI

/// The Terminal menu, with Ghostty's default keys. A key the user rebound in
/// their Ghostty config still works too: libghostty turns it into the same
/// action.
struct TerminalCommands: Commands {
  let store: AppStore

  var body: some Commands {
    CommandMenu("Terminal") {
      let enabled = store.selectedWorktree != nil
      Group {
        Button("New Tab") { store.performOnFocusedPane(.newTab) }
          .keyboardShortcut("t")
        Button("New Agent Tab") {
          if let worktree = store.selectedWorktree { store.newTab(in: worktree, agent: true) }
        }
        .keyboardShortcut("t", modifiers: [.command, .option])
        Divider()
        Button("Split Right") { store.performOnFocusedPane(.split(.horizontal, newFirst: false)) }
          .keyboardShortcut("d")
        Button("Split Down") { store.performOnFocusedPane(.split(.vertical, newFirst: false)) }
          .keyboardShortcut("d", modifiers: [.command, .shift])
        Button("Equalize Splits") { store.performOnFocusedPane(.equalize) }
          .keyboardShortcut("=", modifiers: [.command, .control])
        Divider()
        Button("Next Pane") { store.performOnFocusedPane(.gotoSplit(.next)) }
          .keyboardShortcut("]")
        Button("Previous Pane") { store.performOnFocusedPane(.gotoSplit(.previous)) }
          .keyboardShortcut("[")
        Button("Next Tab") { store.performOnFocusedPane(.gotoTab(.next)) }
          .keyboardShortcut("]", modifiers: [.command, .shift])
        Button("Previous Tab") { store.performOnFocusedPane(.gotoTab(.previous)) }
          .keyboardShortcut("[", modifiers: [.command, .shift])
        Divider()
        Button("Close Pane") { store.performOnFocusedPane(.close) }
          .keyboardShortcut("w")
        Button("Close Tab") { store.performOnFocusedPane(.closeTab) }
          .keyboardShortcut("w", modifiers: [.command, .option])
      }
      .disabled(!enabled)
    }
  }
}
