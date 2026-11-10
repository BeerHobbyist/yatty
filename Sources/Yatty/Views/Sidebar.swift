import AppKit
import SwiftUI

/// The projects and their worktrees. Worktrees whose agent needs the user,
/// works, or finished unseen float out of their project to the top, and
/// sink back once seen to.
struct Sidebar: View {
  @Environment(AppStore.self) private var store
  @FocusState private var filterFocused: Bool

  var body: some View {
    @Bindable var store = store
    let query = store.sidebarFilter
    let filtering = !query.trimmingCharacters(in: .whitespaces).isEmpty
    let all = store.repos.flatMap { store.worktrees[$0.id] ?? [] } + store.hosts.flatMap(\.worktrees)
    let active = store.floatedSections(of: all.filter { matches($0, query: query, project: projectName(of: $0)) })
      .map { section in (state: section.state, worktrees: section.ids.compactMap { id in all.first { $0.id == id } }) }
    let floated = Set(active.flatMap { $0.worktrees.map(\.id) })
    let firstProject = store.repos.first?.id ?? store.hosts.first?.id
    ScrollViewReader { proxy in
      List(selection: selection(floated: floated)) {
        ForEach(active, id: \.state) { section in
          Section {
            ForEach(section.worktrees) { worktree in
              WorktreeRow(worktree: worktree, project: projectName(of: worktree))
                .tag(worktree.id)
                // A faint card in the state's colour: the top reads as its own place.
                .listRowBackground(
                  RoundedRectangle(cornerRadius: 8)
                    .fill(section.state.tint.opacity(0.07))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1))
            }
          } header: {
            FloatedSectionTitle(state: section.state, count: section.worktrees.count)
          }
        }
        ForEach(store.repos) { repo in
          let worktrees = (store.worktrees[repo.id] ?? []).filter {
            !floated.contains($0.id) && matches($0, query: query, project: repo.name)
          }
          if !filtering || !worktrees.isEmpty {
            ProjectHeader(
              id: repo.id, name: repo.name, icon: .repo, worktrees: store.worktrees[repo.id] ?? [],
              isFirst: repo.id == firstProject && active.isEmpty, addHelp: "New worktree in \(repo.name)",
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
          let worktrees = host.worktrees.filter { !floated.contains($0.id) && matches($0, query: query, project: host.host) }
          if !filtering || !worktrees.isEmpty {
            ProjectHeader(
              id: host.id, name: host.host, icon: .server, worktrees: host.worktrees,
              isFirst: host.id == firstProject && active.isEmpty, addHelp: "Add a directory on \(host.host)",
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
      // Rows float up and sink back, not jump.
      .animation(.easeOut(duration: 0.25), value: active.map { $0.worktrees.map(\.id) })
      .onChange(of: store.renamingWorktree?.id) { _, id in
        // Lazily built: a row scrolled away has no field to edit until shown.
        if let id { withAnimation { proxy.scrollTo(id) } }
      }
    }
    .modifier(SidebarListStyle())
    .modifier(SidebarFilterField(text: $store.sidebarFilter, focused: $filterFocused))
    .onChange(of: store.focusingFilter, initial: true) { _, focusing in
      guard focusing else { return }
      filterFocused = true
      // Later: the window shows a hidden sidebar on the same request.
      DispatchQueue.main.async { store.focusingFilter = false }
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

  /// The list's selection. A click on a floated row leaves its project
  /// folded or not as it was.
  private func selection(floated: Set<String>) -> Binding<String?> {
    Binding(
      get: { store.selection },
      set: { id in
        guard let id else { return }
        store.select(id, unfolding: !floated.contains(id))
      })
  }

  private func matches(_ worktree: Worktree, query: String, project: String) -> Bool {
    WorktreeSummary.matches(query, name: store.label(for: worktree), branch: worktree.branch, project: project)
  }

  private func projectName(of worktree: Worktree) -> String {
    store.repo(of: worktree)?.name ?? worktree.host ?? ""
  }
}

/// A floated section's heading: the state's symbol and name in its colour,
/// and how many are in it.
private struct FloatedSectionTitle: View {
  let state: AgentState
  let count: Int

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: state.symbol).imageScale(.small)
      Text(state.title).font(.subheadline.weight(.semibold))
      Spacer()
      Text("\(count)")
        .font(.caption.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(state.tint.opacity(0.16)))
    }
    .foregroundStyle(state.textTint)
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
    .contextMenu {
      actions()
      Divider()
      Button("Move Up") { withAnimation(.easeOut(duration: 0.2)) { store.shiftProject(id, by: -1) } }
      Button("Move Down") { withAnimation(.easeOut(duration: 0.2)) { store.shiftProject(id, by: 1) } }
    }
    .draggable(id)
    .dropDestination(for: String.self) { ids, _ in
      guard let moved = ids.first, moved != id else { return false }
      withAnimation(.easeOut(duration: 0.2)) { store.moveProject(moved, onto: id) }
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
    // Each worktree has one row, floated or not: that's where it's renamed.
    let renaming = store.renamingWorktree?.id == worktree.id
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
              store.focusSelectedTerminal()
            }
            .onExitCommand {
              store.renamingWorktree = nil
              store.focusSelectedTerminal()
            }
            .onAppear {
              draft = store.label(for: worktree)
              DispatchQueue.main.async { nameFocused = true }
            }
            .onChange(of: nameFocused) { _, focused in
              // Clicking away keeps what was typed, as in Finder; only Esc
              // cancels (and clears renamingWorktree before this runs).
              guard !focused, store.renamingWorktree?.id == worktree.id else { return }
              store.renameWorktree(worktree, to: draft)
              store.renamingWorktree = nil
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
        markers.opacity(hovering ? 0 : 1).allowsHitTesting(!hovering)
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
      // Drawn by SwiftUI, as the close button is: a borderless-button menu
      // is AppKit's, which ignores the colour (black on the dark sidebar).
      Menu {
        menu
      } label: {
        actionIcon("ellipsis")
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("More")
      if !worktree.isMain {
        Button {
          store.requestClose(worktree)
        } label: {
          actionIcon("xmark")
        }
        .buttonStyle(.plain)
        .help(worktree.isRemote ? "Remove Directory…" : "Close Worktree…")
      }
    }
    .foregroundStyle(.secondary)
  }

  private func actionIcon(_ symbol: String) -> some View {
    Image(systemName: symbol)
      .frame(width: 18, height: 18)
      .contentShape(Rectangle())
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
