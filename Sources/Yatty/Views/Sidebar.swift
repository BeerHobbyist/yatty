import AppKit
import SwiftUI

/// How the sidebar's rows are tagged. A worktree in "Needs you" is listed a
/// second time, so that row's tag says which of the two was clicked.
enum SidebarSelection {
  static let needsYouPrefix = "needs-you:"

  static func tag(_ worktreeID: String, inNeedsYou: Bool) -> String {
    inNeedsYou ? needsYouPrefix + worktreeID : worktreeID
  }

  static func worktreeID(fromTag tag: String) -> String {
    isNeedsYou(tag) ? String(tag.dropFirst(needsYouPrefix.count)) : tag
  }

  static func isNeedsYou(_ tag: String) -> Bool { tag.hasPrefix(needsYouPrefix) }
}

/// The projects and their worktrees, with what wants the user on top: a
/// filter, "Needs you", then every repository and host.
struct Sidebar: View {
  @Environment(AppStore.self) private var store
  /// The selected worktree was clicked in "Needs you", not in its project.
  @State private var pickedInNeedsYou = false
  /// What the sidebar itself last selected; any other selection is from elsewhere.
  @State private var lastPicked: String?
  @FocusState private var filterFocused: Bool

  var body: some View {
    @Bindable var store = store
    let query = store.sidebarFilter
    let filtering = !query.trimmingCharacters(in: .whitespaces).isEmpty
    let needsYou = needsYouWorktrees(query: query)
    let firstProject = store.repos.first?.id ?? store.hosts.first?.id
    List(selection: selection(needsYou: needsYou)) {
      if !needsYou.isEmpty {
        Section {
          // Their own ids: the same worktree is listed again in its
          // project, and a List mixes up rows that share one.
          ForEach(needsYou.map { (tag: SidebarSelection.tag($0.id, inNeedsYou: true), worktree: $0) }, id: \.tag) {
            WorktreeRow(worktree: $0.worktree, project: projectName(of: $0.worktree)).tag($0.tag)
          }
        } header: {
          SidebarSectionTitle(title: "Needs you", count: needsYou.count)
        }
      }
      ForEach(store.repos) { repo in
        let worktrees = (store.worktrees[repo.id] ?? []).filter { matches($0, query: query, project: repo.name) }
        if !filtering || !worktrees.isEmpty {
          ProjectHeader(
            id: repo.id, name: repo.name, icon: .repo, worktrees: store.worktrees[repo.id] ?? [],
            isFirst: repo.id == firstProject && needsYou.isEmpty, addHelp: "New worktree in \(repo.name)",
            add: { store.newWorktreeRepo = repo }
          ) {
            Button("New Worktree…") { store.newWorktreeRepo = repo }
            Button("Remove Repository…", role: .destructive) { store.pendingRemoval = repo }
          }
          if filtering || !store.foldedProjects.contains(repo.id) {
            if let error = store.loadErrors[repo.id], !filtering {
              Text(error).font(.caption).foregroundStyle(.secondary).selectionDisabled()
            }
            ForEach(worktrees) { worktree in
              WorktreeRow(worktree: worktree).tag(worktree.id)
            }
          }
        }
      }
      ForEach(store.hosts) { host in
        let worktrees = host.worktrees.filter { matches($0, query: query, project: host.host) }
        if !filtering || !worktrees.isEmpty {
          ProjectHeader(
            id: host.id, name: host.host, icon: .server, worktrees: host.worktrees,
            isFirst: host.id == firstProject && needsYou.isEmpty, addHelp: "Add a directory on \(host.host)",
            add: { store.addingHost = AddHostRequest(host: host.host) }
          ) {
            Button("Add Directory…") { store.addingHost = AddHostRequest(host: host.host) }
            Button("Remove Host…", role: .destructive) { store.pendingHostRemoval = host }
          }
          if filtering || !store.foldedProjects.contains(host.id) {
            ForEach(worktrees) { worktree in
              WorktreeRow(worktree: worktree).tag(worktree.id)
            }
          }
        }
      }
    }
    .animation(.easeOut(duration: 0.2), value: needsYou.map(\.id))
    .modifier(SidebarListStyle())
    .modifier(SidebarFilterField(text: $store.sidebarFilter, focused: $filterFocused))
    .onChange(of: store.focusingFilter) { _, focusing in
      guard focusing else { return }
      filterFocused = true
      store.focusingFilter = false
    }
    .onChange(of: store.selection) { _, selection in
      // Selected from elsewhere (the palette, ⇧⌘J, a notification): its
      // project's row shows it.
      if selection != lastPicked { pickedInNeedsYou = false }
    }
    .onKeyPress(.return) {
      guard store.renamingWorktree == nil else { return .ignored }
      store.focusSelectedTerminal()
      return .handled
    }
    .dropDestination(for: URL.self) { urls, _ in
      let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
      for folder in folders { Task { await store.addRepository(at: folder.path) } }
      return !folders.isEmpty
    }
    .overlay {
      if store.repos.isEmpty && store.hosts.isEmpty {
        ContentUnavailableView(
          "No Repositories", systemImage: "folder.badge.plus",
          description: Text("Add one with ⌘O, drop a folder here, or add a directory on another machine with ⌘⇧O."))
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

  /// The list's selection, through the row tags: a click in "Needs you"
  /// selects without unfolding the worktree's project.
  private func selection(needsYou: [Worktree]) -> Binding<String?> {
    Binding(
      get: {
        guard let selected = store.selection else { return nil }
        let inNeedsYou = pickedInNeedsYou && needsYou.contains { $0.id == selected }
        return SidebarSelection.tag(selected, inNeedsYou: inNeedsYou)
      },
      set: { tag in
        guard let tag else { return }
        let inNeedsYou = SidebarSelection.isNeedsYou(tag)
        let id = SidebarSelection.worktreeID(fromTag: tag)
        pickedInNeedsYou = inNeedsYou
        lastPicked = id
        store.select(id, unfolding: !inNeedsYou)
      })
  }

  /// Worktrees whose agent waits on the user, longest wait first.
  private func needsYouWorktrees(query: String) -> [Worktree] {
    let all = store.repos.flatMap { store.worktrees[$0.id] ?? [] } + store.hosts.flatMap(\.worktrees)
    let waiting = all.filter { store.agents.state(of: $0) == .needsAction && matches($0, query: query, project: projectName(of: $0)) }
    let order = WorktreeSummary.needsYouOrder(waiting.map { ($0.id, store.agents.waitingSince(of: $0) ?? .distantFuture) })
    return order.compactMap { id in waiting.first { $0.id == id } }
  }

  private func matches(_ worktree: Worktree, query: String, project: String) -> Bool {
    WorktreeSummary.matches(query, name: store.label(for: worktree), branch: worktree.branch, project: project)
  }

  private func projectName(of worktree: Worktree) -> String {
    store.repo(of: worktree)?.name ?? worktree.host ?? ""
  }
}

/// A heading over sidebar rows that aren't a project: its name and a count.
private struct SidebarSectionTitle: View {
  let title: String
  let count: Int

  var body: some View {
    HStack {
      Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
      Spacer()
      Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        .padding(.horizontal, 6).background(Capsule().fill(.quaternary))
    }
  }
}

/// A repository's or host's row: a click folds its worktrees away or back,
/// as in agentree. Folded, it still shows what inside wants you. Drag it
/// onto another of its kind to reorder.
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
    .draggable(id)
    .dropDestination(for: String.self) { ids, _ in
      guard let moved = ids.first, moved != id else { return false }
      withAnimation(.easeOut(duration: 0.2)) { store.moveProject(moved, before: id) }
      return true
    }
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

/// A worktree: its name, and on a second line always there the one thing
/// worth knowing. Its pull request and agent show on the right; hovering
/// swaps them for its actions. Double-click the name to rename it.
struct WorktreeRow: View {
  let worktree: Worktree
  /// Shown before the second line in "Needs you", where rows from every
  /// project meet.
  var project: String?
  @Environment(AppStore.self) private var store
  @State private var hovering = false
  @State private var draft = ""
  @FocusState private var nameFocused: Bool

  var body: some View {
    let renaming = project == nil && store.renamingWorktree?.id == worktree.id
    HStack(spacing: 8) {
      Octicon(worktree.isRemote ? .fileDirectory : worktree.isMain ? .home : .gitBranch, size: 14)
        .foregroundStyle(Color.accentColor)
      VStack(alignment: .leading, spacing: 1) {
        if renaming {
          TextField("Name", text: $draft, prompt: Text(worktree.name))
            .textFieldStyle(.plain)
            .focused($nameFocused)
            .onSubmit {
              store.renameWorktree(worktree, to: draft)
              store.renamingWorktree = nil
            }
            .onExitCommand { store.renamingWorktree = nil }
            .onAppear {
              draft = store.label(for: worktree)
              DispatchQueue.main.async { nameFocused = true }
            }
            .onChange(of: nameFocused) { _, focused in
              if !focused, store.renamingWorktree?.id == worktree.id { store.renamingWorktree = nil }
            }
        } else {
          Text(store.label(for: worktree))
            .foregroundStyle(worktree.exists ? .primary : .secondary)
            .lineLimit(1)
            .simultaneousGesture(TapGesture(count: 2).onEnded { store.renamingWorktree = worktree })
        }
        TimelineView(.periodic(from: .now, by: 30)) { context in
          Text(secondLine(now: context.date))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer(minLength: 4)
      // Both always laid out, one shown: hovering moves nothing.
      ZStack(alignment: .trailing) {
        markers.opacity(hovering ? 0 : 1)
        actions.opacity(hovering ? 1 : 0).allowsHitTesting(hovering)
      }
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
    .onHover { hovering = $0 || Snapshot.hover == worktree.id }
    .onAppear { if Snapshot.hover == worktree.id { hovering = true } }
    .contextMenu { menu }
    .help(worktree.branch ?? remotePath ?? worktree.path)
  }

  private func secondLine(now: Date) -> String {
    guard worktree.exists else { return "missing" }
    let facts = WorktreeFacts(
      agent: store.agents.state(of: worktree), waitingSince: store.agents.waitingSince(of: worktree),
      pullRequest: store.pullRequests.badge(for: worktree), status: store.gitStatus.status(of: worktree),
      branch: worktree.branch, label: store.label(for: worktree), remotePath: remotePath,
      disconnected: store.disconnectedPanes.contains { $0.worktree == worktree.id }, isMain: worktree.isMain)
    let line = WorktreeSummary.secondLine(facts, now: now)
    return project.map { "\($0) · \(line)" } ?? line
  }

  @ViewBuilder private var markers: some View {
    HStack(spacing: 4) {
      if let pullRequest = store.pullRequests.badge(for: worktree) {
        PullRequestBadge(pullRequest: pullRequest) {
          store.selection = worktree.id
          store.showingPullRequest = true
        }
      }
      AgentGlyph(state: store.agents.state(of: worktree))
    }
  }

  private var actions: some View {
    HStack(spacing: 2) {
      Menu {
        menu
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("More")
      if !worktree.isMain {
        Button {
          store.requestClose(worktree)
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help(worktree.isRemote ? "Remove Directory…" : "Close Worktree…")
      }
    }
    .foregroundStyle(.secondary)
  }

  @ViewBuilder private var menu: some View {
    Button("Rename…") { store.renamingWorktree = worktree }
    if let repo = store.repo(of: worktree) {
      Button("New Worktree…") { store.newWorktreeRepo = repo }
    }
    if !worktree.isRemote {
      Button("Open in Finder") { store.openInFinder(worktree) }
    }
    Button("Copy Path") { store.copyPath(worktree) }
    if !worktree.isMain {
      Divider()
      Button(worktree.isRemote ? "Remove Directory…" : "Close Worktree…", role: .destructive) {
        store.requestClose(worktree)
      }
    }
  }

  /// Where a remote directory is on its host, `~/…` when under its home.
  private var remotePath: String? {
    guard let host = store.host(of: worktree) else { return nil }
    return "\(host.host):" + SSH.displayPath(worktree.path, home: host.home)
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

/// The native sidebar search field; in snapshots, where there's no split
/// view to hold it, a plain field above the list stands in.
private struct SidebarFilterField: ViewModifier {
  @Binding var text: String
  var focused: FocusState<Bool>.Binding

  func body(content: Content) -> some View {
    if Snapshot.isActive {
      content.safeAreaInset(edge: .top) {
        TextField("Filter", text: $text).textFieldStyle(.roundedBorder).padding(.horizontal, 10).padding(.top, 6)
      }
    } else {
      content
        .searchable(text: $text, placement: .sidebar, prompt: "Filter")
        .searchFocused(focused)
    }
  }
}
