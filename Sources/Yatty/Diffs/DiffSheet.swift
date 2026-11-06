import SwiftUI

/// Picks what to diff and opens it in the user's viewer, in a tab of its
/// own — agentree's diff picker.
struct DiffSheet: View {
  let worktree: Worktree
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss

  private enum Choice: Hashable {
    case working, staged, base, ref, commits
  }

  @State private var choice = Choice.working
  @State private var base = ""
  @State private var ref = ""
  @State private var commits: [Commit] = []
  @State private var cursor: String?
  @State private var mark: String?
  @State private var available: [DiffViewer] = []

  var body: some View {
    let viewer = DiffViewers.resolve(store.diffViewer, available: available)
    VStack(alignment: .leading, spacing: 14) {
      Text("Open a Diff in \(store.label(for: worktree))").font(.headline)
      Picker("Show", selection: $choice) {
        Text("Working changes").tag(Choice.working)
        Text("Staged").tag(Choice.staged)
        Text(hasBase ? "vs \(base)" : "vs base branch (none: no origin remote)").tag(Choice.base)
          .disabled(!hasBase)
        Text("Specific ref…").tag(Choice.ref)
        Text("Commits…").tag(Choice.commits)
      }
      .pickerStyle(.radioGroup)

      if choice == .ref {
        TextField("A ref, commit or range", text: $ref, prompt: Text("main~3, v1.2, a1b2c3..HEAD"))
          .textFieldStyle(.roundedBorder)
          .onSubmit { open(viewer) }
      }
      if choice == .commits { commitList }

      HStack {
        Menu("Viewer: \(viewer.label)") {
          ForEach(available.isEmpty ? [.git] : available, id: \.self) { option in
            Button(option.label) { store.setDiffViewer(option) }
          }
        }
        .fixedSize()
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Open") { open(viewer) }.keyboardShortcut(.defaultAction).disabled(target == nil)
      }
    }
    .padding(20)
    .frame(width: 520)
    .task { await load() }
  }

  private var commitList: some View {
    VStack(alignment: .leading, spacing: 6) {
      List(commits, selection: $cursor) { commit in
        HStack(spacing: 8) {
          Image(systemName: mark == commit.sha ? "largecircle.fill.circle" : "circle")
            .foregroundStyle(mark == commit.sha ? Color.accentColor : .secondary)
            .onTapGesture { mark = mark == commit.sha ? nil : commit.sha }
            .help("Mark the other end of the range")
          Text(commit.short).font(.caption.monospaced()).foregroundStyle(.secondary)
          Text(commit.subject).lineLimit(1)
        }
        .tag(commit.sha)
      }
      .frame(height: 200)
      Text(pick?.label ?? "Pick a commit; mark another to diff the range between them.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  /// `Git.defaultBase` falls back to HEAD without an origin: no base then.
  private var hasBase: Bool { !base.isEmpty && base != "HEAD" }

  private var pick: (range: String, label: String)? {
    guard let cursor, let index = commits.firstIndex(where: { $0.sha == cursor }) else { return nil }
    return DiffViewers.pickCommits(commits, cursor: index, mark: mark)
  }

  private var target: DiffTarget? {
    switch choice {
    case .working: .working
    case .staged: .staged
    case .base: hasBase ? .base(base) : nil
    case .ref: ref.trimmingCharacters(in: .whitespaces).isEmpty ? nil : .ref(ref.trimmingCharacters(in: .whitespaces))
    case .commits: pick.map { .range($0.range) }
    }
  }

  private func load() async {
    guard let repo = store.repo(of: worktree) else { return }
    base = await Git.defaultBase(root: repo.path)
    commits = await Git.branchCommits(path: worktree.path, base: base)
    cursor = commits.first?.sha
    available = await Task.detached { DiffViewers.available(in: Run.loginPath) }.value
  }

  private func open(_ viewer: DiffViewer) {
    guard let target else { return }
    store.newTab(in: worktree, command: DiffViewers.command(viewer, args: target.args), name: "diff: \(target.title)")
    dismiss()
  }
}
