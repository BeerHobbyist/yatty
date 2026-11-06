import SwiftUI

struct ContentView: View {
  @Environment(AppStore.self) private var store

  var body: some View {
    @Bindable var store = store
    Group {
      if Snapshot.isActive {
        // macOS composites a split view's sidebar outside the app, where a
        // snapshot can't see it; a plain row of the same views can be drawn.
        HStack(spacing: 0) {
          Sidebar().frame(width: 240)
          Divider()
          DetailView()
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
          store.chooseRepository()
        } label: {
          Label("Add Repository", systemImage: "folder.badge.plus")
        }
        .help("Add a repository (⌘O)")
      }
    }
  }
}

struct WorktreeRow: View {
  let worktree: Worktree

  var body: some View {
    Label {
      Text(worktree.name)
        .foregroundStyle(worktree.exists ? .primary : .secondary)
    } icon: {
      Image(systemName: worktree.isMain ? "house" : "arrow.triangle.branch")
    }
    .help(worktree.branch ?? worktree.path)
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
      .navigationTitle(worktree.name)
      .navigationSubtitle(store.repo(of: worktree)?.name ?? "")
    } else {
      ContentUnavailableView(
        "No Worktree Selected", systemImage: "sidebar.left",
        description: Text(
          store.repos.isEmpty ? "Add a repository with ⌘O." : "Pick one in the sidebar, or press ⌘N for a new one."))
    }
  }
}

struct NewWorktreeSheet: View {
  let repo: Repo
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var branch = ""
  @State private var base = ""
  @State private var error: String?
  @State private var busy = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("New Worktree in \(repo.name)").font(.headline)
      Form {
        TextField("Branch", text: $branch, prompt: Text("feature/login"))
        TextField("Based on", text: $base, prompt: Text("HEAD"))
      }
      if let error {
        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Create") { create() }
          .keyboardShortcut(.defaultAction)
          .disabled(trimmed(branch).isEmpty || busy)
      }
    }
    .padding(20)
    .frame(width: 420)
    .task { base = await Git.defaultBase(root: repo.path) }
  }

  private func create() {
    busy = true
    error = nil
    let branch = trimmed(branch)
    let base = trimmed(base).isEmpty ? "HEAD" : trimmed(base)
    Task {
      do {
        try await store.createWorktree(in: repo, branch: branch, base: base)
        dismiss()
      } catch {
        self.error = error.localizedDescription
        busy = false
      }
    }
  }

  private func trimmed(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines)
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
