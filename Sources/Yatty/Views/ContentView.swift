import SwiftUI

struct ContentView: View {
  @Environment(AppStore.self) private var store
  @State private var labelDraft = ""

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
    .alert(
      "Rename Worktree",
      isPresented: Binding(get: { store.renamingWorktree != nil }, set: { if !$0 { store.renamingWorktree = nil } }),
      presenting: store.renamingWorktree
    ) { worktree in
      TextField("Name", text: $labelDraft)
      Button("Rename") { store.renameWorktree(worktree, to: labelDraft) }
      Button("Cancel", role: .cancel) {}
    } message: { worktree in
      Text("Only the sidebar's name changes: the branch \(worktree.branch ?? "") and its folder keep theirs. Leave it empty to use the branch's name.")
    }
    .onChange(of: store.renamingWorktree) { _, worktree in
      labelDraft = worktree.map { store.labels[$0.id] ?? "" } ?? ""
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

struct Sidebar: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    @Bindable var store = store
    List(selection: $store.selection) {
      ForEach(store.repos) { repo in
        Section {
          if let error = store.loadErrors[repo.id] {
            Text(error).font(.caption).foregroundStyle(.secondary)
          }
          ForEach(store.worktrees[repo.id] ?? []) { worktree in
            WorktreeRow(worktree: worktree)
              .tag(worktree.id)
              .contextMenu {
                Button("New Worktree…") { store.newWorktreeRepo = repo }
                Button("Rename…") { store.renamingWorktree = worktree }
                if !worktree.isMain {
                  Button("Close Worktree…", role: .destructive) {
                    store.pendingClose = PendingClose(repo: repo, worktree: worktree)
                  }
                }
              }
          }
        } header: {
          HStack {
            Text(repo.name)
            Spacer()
            Button {
              store.newWorktreeRepo = repo
            } label: {
              Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New worktree in \(repo.name)")
          }
          .contextMenu {
            Button("New Worktree…") { store.newWorktreeRepo = repo }
            Button("Remove Repository…", role: .destructive) { store.pendingRemoval = repo }
          }
        }
      }
    }
    .modifier(SidebarListStyle())
    .safeAreaInset(edge: .bottom) { AgentCounts() }
    .onKeyPress(.return) {
      store.focusSelectedTerminal()
      return .handled
    }
    .overlay {
      if store.repos.isEmpty {
        ContentUnavailableView(
          "No Repositories", systemImage: "folder.badge.plus", description: Text("Add one with ⌘O."))
      }
    }
    .toolbar {
      ToolbarItem {
        Button {
          store.addingRepository = true
        } label: {
          Label("Add Repository", systemImage: "folder.badge.plus")
        }
        .help("Add a repository (⌘O)")
      }
    }
  }
}

/// How many agents need you, work, or are done; a click goes to the next one.
struct AgentCounts: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    let needs = store.agents.count(.needsAction)
    let working = store.agents.count(.working)
    let done = store.agents.count(.done)
    if needs + working + done > 0 {
      HStack(spacing: 12) {
        if needs > 0 { count(needs, .needsAction) }
        if working > 0 { count(working, .working) }
        if done > 0 { count(done, .done) }
        Spacer()
      }
      .font(.callout)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(.bar)
    }
  }

  private func count(_ n: Int, _ state: AgentState) -> some View {
    Button {
      store.jumpToNextAgent()
    } label: {
      HStack(spacing: 4) {
        AgentGlyph(state: state)
        Text("\(n)").monospacedDigit()
      }
    }
    .buttonStyle(.borderless)
    .help("Go to the next agent that needs you (⌘⇧J)")
  }
}

struct WorktreeRow: View {
  let worktree: Worktree
  @Environment(AppStore.self) private var store

  var body: some View {
    let status = store.gitStatus.status(of: worktree)
    let selected = store.selection == worktree.id
    Label {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(store.label(for: worktree))
            .foregroundStyle(worktree.exists ? .primary : .secondary)
            .lineLimit(1)
          if !worktree.exists {
            Text("missing").font(.caption).foregroundStyle(.secondary)
          }
          if let changed = status?.changed, changed > 0 {
            Text("●\(changed)").font(.caption.monospacedDigit()).foregroundStyle(.orange)
              .help("\(changed) changed file\(changed == 1 ? "" : "s")")
          }
          Spacer(minLength: 4)
          if let pullRequest = store.pullRequests.badge(for: worktree) {
            PullRequestBadge(pullRequest: pullRequest) {
              store.selection = worktree.id
              store.showingPullRequest = true
            }
          }
          AgentGlyph(state: store.agents.state(of: worktree))
        }
        if selected, let details = secondLine(status) {
          Text(details).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
      }
    } icon: {
      Image(systemName: worktree.isMain ? "house" : "arrow.triangle.branch")
    }
    .help(worktree.branch ?? worktree.path)
  }

  /// The selected row's details: the branch when it isn't the name shown,
  /// then +/− and ahead/behind, each only when there's something to say.
  private func secondLine(_ status: GitStatus?) -> String? {
    var parts: [String] = []
    if let branch = worktree.branch, branch != store.label(for: worktree) { parts.append(branch) }
    if let status {
      if status.added + status.removed > 0 { parts.append("+\(status.added) −\(status.removed)") }
      if status.ahead > 0 { parts.append("↑\(status.ahead)") }
      if status.behind > 0 { parts.append("↓\(status.behind)") }
    }
    return parts.isEmpty ? nil : parts.joined(separator: "  ")
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
      .navigationSubtitle(store.repo(of: worktree)?.name ?? "")
    } else {
      ContentUnavailableView(
        "No Worktree Selected", systemImage: "sidebar.left",
        description: Text(
          store.repos.isEmpty ? "Add a repository with ⌘O." : "Pick one in the sidebar, or press ⌘N for a new one."))
    }
  }
}

/// The sidebar list style, except in snapshots: vibrant sidebar text uses a
/// blend that a snapshot's layer render can't draw, so it comes out blank.
private struct SidebarListStyle: ViewModifier {
  func body(content: Content) -> some View {
    if Snapshot.isActive {
      content.listStyle(.inset)
    } else {
      content.listStyle(.sidebar)
    }
  }
}
