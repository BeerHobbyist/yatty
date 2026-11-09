import SwiftUI

struct ContentView: View {
  @Environment(AppStore.self) private var store
  @Environment(\.openSettings) private var openSettings
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
    let firstProject = store.repos.first?.id ?? store.hosts.first?.id
    List(selection: $store.selection) {
      ForEach(store.repos) { repo in
        let worktrees = store.worktrees[repo.id] ?? []
        ProjectHeader(
          id: repo.id, name: repo.name, icon: .repo, worktrees: worktrees, isFirst: repo.id == firstProject,
          addHelp: "New worktree in \(repo.name)", add: { store.newWorktreeRepo = repo }
        ) {
          Button("New Worktree…") { store.newWorktreeRepo = repo }
          Button("Remove Repository…", role: .destructive) { store.pendingRemoval = repo }
        }
        if !store.foldedProjects.contains(repo.id) {
          if let error = store.loadErrors[repo.id] {
            Text(error).font(.caption).foregroundStyle(.secondary).selectionDisabled()
          }
          ForEach(worktrees) { worktree in
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
        }
      }
      ForEach(store.hosts) { host in
        ProjectHeader(
          id: host.id, name: host.host, icon: .server, worktrees: host.worktrees,
          isFirst: host.id == firstProject, addHelp: "Add a directory on \(host.host)",
          add: { store.addingHost = AddHostRequest(host: host.host) }
        ) {
          Button("Add Directory…") { store.addingHost = AddHostRequest(host: host.host) }
          Button("Remove Host…", role: .destructive) { store.pendingHostRemoval = host }
        }
        if !store.foldedProjects.contains(host.id) {
          ForEach(host.worktrees) { worktree in
            WorktreeRow(worktree: worktree)
              .tag(worktree.id)
              .contextMenu {
                Button("Rename…") { store.renamingWorktree = worktree }
                Button("Remove Directory…", role: .destructive) { store.pendingDirectoryRemoval = worktree }
              }
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
      if store.repos.isEmpty && store.hosts.isEmpty {
        ContentUnavailableView(
          "No Repositories", systemImage: "folder.badge.plus",
          description: Text("Add one with ⌘O, or a directory on another machine with ⌘⇧O."))
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
      ToolbarItem {
        Button {
          store.addingHost = AddHostRequest()
        } label: {
          Label("Add SSH Host", systemImage: "server.rack")
        }
        .help("Add a directory on another machine (⌘⇧O)")
      }
    }
  }
}

/// A repository's or host's row: a click folds its worktrees away or back,
/// as in agentree. Folded, it still shows what inside wants you.
struct ProjectHeader<Actions: View>: View {
  let id: String
  let name: String
  let icon: Octicon.Name
  let worktrees: [Worktree]
  let isFirst: Bool
  let addHelp: String
  let add: () -> Void
  @ViewBuilder let actions: () -> Actions
  @Environment(AppStore.self) private var store

  var body: some View {
    let folded = store.foldedProjects.contains(id)
    HStack(spacing: 4) {
      Button {
        withAnimation(.easeOut(duration: 0.15)) { store.toggleFold(id) }
      } label: {
        HStack(spacing: 5) {
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(folded ? 0 : 90))
            .frame(width: 10)
          Octicon(icon, size: 11).foregroundStyle(.secondary)
          Text(name)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          if folded { summary }
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(folded ? "Show \(name)" : "Hide \(name)")
      Button(action: add) {
        Image(systemName: "plus")
      }
      .buttonStyle(.borderless)
      .help(addHelp)
    }
    .padding(.top, isFirst ? 0 : 8)
    .contextMenu { actions() }
    .selectionDisabled()
  }

  /// The most urgent agent inside, whether any worktree has changes, and how many there are.
  @ViewBuilder private var summary: some View {
    let urgent = worktrees.compactMap { store.agents.state(of: $0) }.min()
    let changed = worktrees.filter { (store.gitStatus.status(of: $0)?.changed ?? 0) > 0 }.count
    AgentGlyph(state: urgent)
    if changed > 0 {
      Text("●").font(.caption).foregroundStyle(.orange)
        .help("\(changed) worktree\(changed == 1 ? " has" : "s have") changes")
    }
    Text("\(worktrees.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
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
      Octicon(worktree.isRemote ? .fileDirectory : worktree.isMain ? .home : .gitBranch, size: 14)
    }
    .help(worktree.branch ?? remotePath ?? worktree.path)
  }

  /// Where a remote directory is on its host, `~/…` when under its home.
  private var remotePath: String? {
    guard let host = store.host(of: worktree) else { return nil }
    return "\(host.host):" + SSH.displayPath(worktree.path, home: host.home)
  }

  /// The selected row's details: the branch when it isn't the name shown,
  /// then +/− and ahead/behind, each only when there's something to say.
  private func secondLine(_ status: GitStatus?) -> String? {
    var parts: [String] = []
    if let remotePath { parts.append(remotePath) }
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
