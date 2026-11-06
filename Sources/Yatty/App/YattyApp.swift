import GhosttyKit
import SwiftUI

@main
struct YattyApp: App {
  @State private var store: AppStore

  init() {
    if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
      fatalError("libghostty failed to initialize")
    }
    _store = State(initialValue: AppStore())
  }

  var body: some Scene {
    Window("Yatty", id: "main") {
      ContentView()
        .environment(store)
        .frame(minWidth: 720, minHeight: 420)
    }
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("New Worktree…") { store.newWorktreeForSelection() }
          .keyboardShortcut("n")
          .disabled(store.repos.isEmpty)
        Button("Add Repository…") { store.chooseRepository() }
          .keyboardShortcut("o")
      }
      CommandMenu("Worktree") {
        Button("Close Worktree…") { store.requestCloseSelected() }
          .disabled(store.selectedWorktree.map { $0.isMain } ?? true)
      }
    }
  }
}
