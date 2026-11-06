import SwiftUI

/// The Terminal menu, with Ghostty's default keys. A key the user rebound in
/// their Ghostty config still works too: libghostty turns it into the same
/// action.
struct TerminalCommands: Commands {
  let store: AppStore

  var body: some Commands {
    CommandMenu("Terminal") {
      let enabled = store.commandContext.hasTerminals
      Group {
        Button("New Tab") { store.performOnFocusedPane(.newTab) }
          .keyboardShortcut(Shortcuts.newTab)
        Button("New Agent Tab") {
          if let worktree = store.selectedWorktree { store.newTab(in: worktree, agent: true) }
        }
        .keyboardShortcut(Shortcuts.newAgentTab)
        Button("Open Diff…") { store.diffingWorktree = store.selectedWorktree }
          .keyboardShortcut(Shortcuts.openDiff)
          // Diffs run git here; a remote directory's files are there.
          .disabled(!store.commandContext.canDiff)
        Divider()
        Button("Split Right") { store.performOnFocusedPane(.split(.horizontal, newFirst: false)) }
          .keyboardShortcut(Shortcuts.splitRight)
        Button("Split Down") { store.performOnFocusedPane(.split(.vertical, newFirst: false)) }
          .keyboardShortcut(Shortcuts.splitDown)
        Button("Equalize Splits") { store.performOnFocusedPane(.equalize) }
          .keyboardShortcut(Shortcuts.equalize)
        Divider()
        Button("Next Pane") { store.performOnFocusedPane(.gotoSplit(.next)) }
          .keyboardShortcut(Shortcuts.nextPane)
        Button("Previous Pane") { store.performOnFocusedPane(.gotoSplit(.previous)) }
          .keyboardShortcut(Shortcuts.previousPane)
        Button("Next Tab") { store.performOnFocusedPane(.gotoTab(.next)) }
          .keyboardShortcut(Shortcuts.nextTab)
        Button("Previous Tab") { store.performOnFocusedPane(.gotoTab(.previous)) }
          .keyboardShortcut(Shortcuts.previousTab)
        Divider()
        Button("Close Pane") { store.performOnFocusedPane(.close) }
          .keyboardShortcut(Shortcuts.closePane)
        Button("Close Tab") { store.performOnFocusedPane(.closeTab) }
          .keyboardShortcut(Shortcuts.closeTab)
      }
      .disabled(!enabled)
    }
  }
}
