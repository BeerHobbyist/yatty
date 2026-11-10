import SwiftUI

/// The Terminal menu, with Ghostty's default keys. A key the user rebound in
/// their Ghostty config still works too: libghostty turns it into the same
/// action.
struct TerminalCommands: Commands {
  let store: AppStore
  /// Only while the main window is in front: in a diff window, ⌘W must not
  /// close the terminal pane focused behind it.
  @FocusedValue(\.isMainWindow) private var isMainWindow

  var body: some Commands {
    CommandMenu("Terminal") {
      let enabled = store.commandContext.hasTerminals && isMainWindow == true
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
        Button(store.commandContext.showingCode ? "Hide Code" : "Show Code") {
          if let worktree = store.selectedWorktree { store.toggleCode(in: worktree) }
        }
        .keyboardShortcut(Shortcuts.showCode)
        .disabled(!store.commandContext.canShowCode)
        Button("Go to File…") {
          if let worktree = store.selectedWorktree { store.codeQuickOpen = store.layout(for: worktree).selectedTab }
        }
        .keyboardShortcut(Shortcuts.goToFile)
        .disabled(!store.commandContext.canGoToFile)
        Divider()
        Group {
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
        }
        // A diff tab has no terminal to split or move between.
        .disabled(!store.commandContext.canSplit)
        Button("Next Tab") { store.performOnFocusedPane(.gotoTab(.next)) }
          .keyboardShortcut(Shortcuts.nextTab)
        Button("Previous Tab") { store.performOnFocusedPane(.gotoTab(.previous)) }
          .keyboardShortcut(Shortcuts.previousTab)
        Divider()
        Button(store.commandContext.closeTitle) { store.performOnFocusedPane(.close) }
          .keyboardShortcut(Shortcuts.closePane)
        Button("Close Tab") { store.performOnFocusedPane(.closeTab) }
          .keyboardShortcut(Shortcuts.closeTab)
      }
      .disabled(!enabled)
    }
  }
}

/// Set by the main window's content: menus that act on its terminals check it.
struct MainWindowKey: FocusedValueKey {
  typealias Value = Bool
}

extension FocusedValues {
  var isMainWindow: Bool? {
    get { self[MainWindowKey.self] }
    set { self[MainWindowKey.self] = newValue }
  }
}
