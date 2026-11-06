import GhosttyKit
import SwiftUI

@main
struct YattyApp: App {
  @State private var store: AppStore

  init() {
    // A CLI client that hangs up mid-answer must not take the app down.
    signal(SIGPIPE, SIG_IGN)
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
      CommandGroup(after: .sidebar) {
        Button("Show Pull Request") { store.showingPullRequest.toggle() }
          .keyboardShortcut("p", modifiers: [.command, .option])
        Button("Refresh Pull Requests") { store.refreshPullRequests() }
          .keyboardShortcut("r")
        Button("Merge Pull Request…") {
          if let worktree = store.selectedWorktree { store.mergingWorktree = worktree }
        }
        .disabled(store.selectedWorktree.flatMap { store.pullRequests.badge(for: $0) }.map { $0.merged } ?? true)
        Divider()
      }
      CommandMenu("Worktree") {
        Button("Close Worktree…") { store.requestCloseSelected() }
          .disabled(store.selectedWorktree.map { $0.isMain } ?? true)
      }
      TerminalCommands(store: store)
      CommandMenu("Agents") {
        Button("Go to Next Agent") { store.jumpToNextAgent() }
          .keyboardShortcut("j", modifiers: [.command, .shift])
        Divider()
        Toggle(
          "Track Every Claude",
          isOn: Binding(
            get: { store.trackingEveryClaude },
            set: { on in if on { store.confirmingTracking = true } else { store.setTracking(false) } }))
      }
    }
  }
}
