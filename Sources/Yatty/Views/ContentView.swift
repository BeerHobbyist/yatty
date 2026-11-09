import SwiftUI

struct ContentView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    @Bindable var store = store
    Group {
      if Snapshot.isActive {
        // macOS composites a split view's sidebar outside the app, where a
        // snapshot can't see it; a plain row of the same views can be drawn.
        HStack(spacing: 0) {
          Sidebar().frame(width: 240)
          Divider()
          DetailView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else {
        NavigationSplitView {
          Sidebar()
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 400)
        } detail: {
          DetailView()
        }
      }
    }
    .sheet(isPresented: $store.addingRepository) {
      AddRepositorySheet()
    }
    .sheet(item: $store.addingHost) { request in
      AddHostSheet(request: request)
    }
    .task(id: store.openingSettings) {
      guard store.openingSettings else { return }
      store.openingSettings = false
      openSettings()
    }
    .sheet(isPresented: $store.showingPalette, onDismiss: { store.paletteClosed() }) {
      CommandPalette(commands: store.commands) { store.pickedCommand = $0 }
    }
    .sheet(isPresented: $store.showingHelp, onDismiss: { store.focusSelectedTerminal() }) {
      VStack(spacing: 0) {
        HelpView(commands: store.commands)
        Divider()
        HStack {
          Spacer()
          Button("Done") { store.showingHelp = false }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
      }
      .frame(width: 560, height: 620)
    }
    .confirmationDialog(
      "Remove \(store.pendingHostRemoval?.host ?? "")?",
      isPresented: Binding(
        get: { store.pendingHostRemoval != nil }, set: { if !$0 { store.pendingHostRemoval = nil } }),
      presenting: store.pendingHostRemoval
    ) { host in
      Button("Remove Host", role: .destructive) { Task { await store.removeHost(host) } }
    } message: { _ in
      Text("Ends the terminals of its directories there (once it can be reached). Nothing on the host is touched.")
    }
    .confirmationDialog(
      "Remove \(store.pendingDirectoryRemoval.map { store.label(for: $0) } ?? "")?",
      isPresented: Binding(
        get: { store.pendingDirectoryRemoval != nil }, set: { if !$0 { store.pendingDirectoryRemoval = nil } }),
      presenting: store.pendingDirectoryRemoval
    ) { worktree in
      Button("Remove Directory", role: .destructive) { Task { await store.removeRemoteDirectory(worktree) } }
    } message: { _ in
      Text("Ends its terminals on the host (once it can be reached). Its files stay.")
    }
    .sheet(item: $store.diffingWorktree) { worktree in
      DiffSheet(worktree: worktree)
    }
    .sheet(item: $store.mergingWorktree) { worktree in
      MergeSheet(worktree: worktree)
    }
    .sheet(item: $store.reviewingComments) { worktree in
      CommentReviewSheet(worktree: worktree)
    }
    .sheet(item: $store.newWorktreeRepo) { repo in
      NewWorktreeSheet(repo: repo)
    }
    .alert(
      store.alert?.title ?? "",
      isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } }),
      presenting: store.alert
    ) { _ in
      Button("OK") {}
    } message: { alert in
      Text(alert.message)
    }
    .confirmationDialog(
      "Close \(store.pendingClose?.worktree.name ?? "")?",
      isPresented: Binding(get: { store.pendingClose != nil }, set: { if !$0 { store.pendingClose = nil } }),
      presenting: store.pendingClose
    ) { pending in
      Button("Close Worktree", role: .destructive) {
        Task { await store.closeWorktree(pending) }
      }
    } message: { pending in
      Text(
        "Deletes \(pending.worktree.path) and any uncommitted changes in it, and ends its terminal. "
          + "The branch \(pending.worktree.branch ?? "") stays.")
    }
    .confirmationDialog(
      "Track every claude?", isPresented: $store.confirmingTracking
    ) {
      Button("Track Every Claude") { store.setTracking(true) }
    } message: {
      Text(
        "Adds Yatty's status hooks to \(ClaudeSettings.url.path), so a claude you start by hand in a Yatty "
          + "terminal reports too. They do nothing outside Yatty, leave your other settings alone, and come "
          + "out again when you turn this off.")
    }
    .confirmationDialog(
      "Remove \(store.pendingRemoval?.name ?? "")?",
      isPresented: Binding(get: { store.pendingRemoval != nil }, set: { if !$0 { store.pendingRemoval = nil } }),
      presenting: store.pendingRemoval
    ) { repo in
      Button("Remove Repository", role: .destructive) {
        Task { await store.removeRepository(repo) }
      }
    } message: { _ in
      Text("Ends the terminals of its worktrees. Nothing on disk is touched.")
    }
  }
}

struct DetailView: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    if let worktree = store.selectedWorktree {
      Group {
        if !worktree.exists {
          ContentUnavailableView(
            "Directory Missing", systemImage: "questionmark.folder",
            description: Text("\(worktree.path) no longer exists."))
        } else {
          TerminalsView(worktree: worktree)
        }
      }
      .navigationTitle(store.label(for: worktree))
      .navigationSubtitle(store.repo(of: worktree)?.name ?? worktree.host ?? "")
      .modifier(PullRequestColumn(worktree: worktree))
      .toolbar {
        ToolbarItem {
          Button {
            store.showingPullRequest.toggle()
          } label: {
            Label("Pull Request", systemImage: "sidebar.right")
          }
          .help("Show the pull request (⌥⌘P)")
          .disabled(worktree.isRemote)
        }
      }
    } else {
      ContentUnavailableView(
        "No Worktree Selected", systemImage: "sidebar.left",
        description: Text(
          store.repos.isEmpty ? "Add a repository with ⌘O." : "Pick one in the sidebar, or press ⌘N for a new one."))
    }
  }
}

/// The pull request inspector beside the terminals. In snapshots it's a
/// plain column: macOS draws an inspector outside the app, like a sidebar.
private struct PullRequestColumn: ViewModifier {
  let worktree: Worktree
  @Environment(AppStore.self) private var store

  func body(content: Content) -> some View {
    if worktree.isRemote {
      // No git there: no pull request to show.
      content
    } else if Snapshot.isActive {
      HStack(spacing: 0) {
        content
        if store.showingPullRequest {
          Divider()
          PullRequestInspector(worktree: worktree).frame(width: 340)
        }
      }
    } else {
      content.inspector(isPresented: Bindable(store).showingPullRequest) {
        PullRequestInspector(worktree: worktree)
          .inspectorColumnWidth(min: 260, ideal: 320, max: 520)
      }
    }
  }
}
