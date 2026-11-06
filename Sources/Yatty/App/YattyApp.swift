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
    DispatchQueue.main.async { MainActor.assumeIsolated { Snapshot.scheduleIfRequested() } }
  }

  var body: some Scene {
    Window("Yatty", id: "main") {
      ContentView()
        .environment(store)
        .frame(minWidth: 720, minHeight: 420)
    }
    .defaultSize(width: 1280, height: 800)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("New Worktree…") { store.newWorktreeForSelection() }
          .keyboardShortcut("n")
          .disabled(store.repos.isEmpty)
        Button("Add Repository…") { store.addingRepository = true }
          .keyboardShortcut("o")
      }
      // File > Close (⌘W) would close the whole window; ⌘W closes a pane instead.
      CommandGroup(replacing: .saveItem) {}
      CommandMenu("Worktree") {
        Button("Close Worktree…") { store.requestCloseSelected() }
          .disabled(store.selectedWorktree.map { $0.isMain } ?? true)
      }
      TerminalCommands(store: store)
    }
  }
}
