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
      let context = store.commandContext
      CommandGroup(replacing: .newItem) {
        Button("New Worktree…") { store.newWorktreeForSelection() }
          .keyboardShortcut(Shortcuts.newWorktree)
          .disabled(!context.canNewWorktree)
        Button("Add Repository…") { store.addingRepository = true }
          .keyboardShortcut(Shortcuts.addRepository)
        Button("Add SSH Host…") { store.addingHost = AddHostRequest() }
          .keyboardShortcut(Shortcuts.addHost)
      }
      CommandGroup(replacing: .help) {
        Button("Keyboard Shortcuts") { store.showingHelp = true }
          .keyboardShortcut(Shortcuts.help)
      }
      // File > Close (⌘W) would close the whole window; ⌘W closes a pane instead.
      CommandGroup(replacing: .saveItem) {}
      CommandGroup(after: .sidebar) {
        Button("Command Palette…") { store.showingPalette.toggle() }
          .keyboardShortcut(Shortcuts.palette)
        Button("Filter Worktrees") { store.focusingFilter = true }
          .keyboardShortcut(Shortcuts.filterWorktrees)
        Divider()
        Button("Show Pull Request") { store.showingPullRequest.toggle() }
          .keyboardShortcut(Shortcuts.showPullRequest)
          .disabled(!context.canShowPullRequest)
        Button("Refresh Pull Requests") { store.refreshPullRequests() }
          .keyboardShortcut(Shortcuts.refresh)
        Button("Merge Pull Request…") {
          if let worktree = store.selectedWorktree { store.mergingWorktree = worktree }
        }
        .disabled(!context.canMerge)
        Button("Review Comments…") {
          if let worktree = store.selectedWorktree { store.reviewingComments = worktree }
        }
        .disabled(!context.canReviewComments)
        Divider()
      }
      CommandMenu("Worktree") {
        Button(context.selected?.isRemote == true ? "Remove Directory…" : "Close Worktree…") {
          store.requestCloseSelected()
        }
        .disabled(!context.canCloseWorktree)
      }
      TerminalCommands(store: store)
      CommandMenu("Agents") {
        Button("Go to Next Agent") { store.jumpToNextAgent() }
          .keyboardShortcut(Shortcuts.nextAgent)
        Divider()
        Toggle(
          "Track Every Claude",
          isOn: Binding(
            get: { store.trackingEveryClaude },
            set: { on in if on { store.confirmingTracking = true } else { store.setTracking(false) } }))
      }
    }
    Settings {
      SettingsView().environment(store)
    }
  }
}
