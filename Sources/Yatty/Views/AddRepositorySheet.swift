import SwiftUI

/// Pick any repo `gh` can see: it's cloned into the clone folder (or an
/// existing clone is reused) and added. A local folder works too.
struct AddRepositorySheet: View {
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var highlighted: RemoteRepo.ID?
  @State private var cloning: RemoteRepo?
  @State private var error: String?
  @FocusState private var searchFocused: Bool

  var body: some View {
    let catalog = store.catalog
    let results = RemoteRepo.ranked(catalog.repos, query: query)
    VStack(alignment: .leading, spacing: 12) {
      Text("Add Repository").font(.headline)
      TextField("Search repositories", text: $query)
        .textFieldStyle(.roundedBorder)
        .focused($searchFocused)
        .onKeyPress(.downArrow) {
          move(1, in: results)
          return .handled
        }
        .onKeyPress(.upArrow) {
          move(-1, in: results)
          return .handled
        }
        .onSubmit { if let repo = current(in: results) { add(repo) } }

      ScrollViewReader { proxy in
        List(results, selection: $highlighted) { repo in
          RemoteRepoRow(repo: repo)
            .tag(repo.id)
            .id(repo.id)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture(count: 2).onEnded { add(repo) })
        }
        .onChange(of: highlighted) { _, id in
          if let id { proxy.scrollTo(id) }
        }
      }
      .frame(height: 320)

      status(catalog: catalog, count: results.count)

      HStack {
        Button("Choose Local Folder…") {
          dismiss()
          store.chooseRepository()
        }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Add") { if let repo = current(in: results) { add(repo) } }
          .keyboardShortcut(.defaultAction)
          .disabled(current(in: results) == nil || cloning != nil)
      }
    }
    .padding(20)
    .frame(width: 560)
    .onAppear {
      catalog.loadIfNeeded()
      searchFocused = true
    }
    .onChange(of: query) { _, newQuery in
      highlighted = RemoteRepo.ranked(catalog.repos, query: newQuery).first?.id
    }
    // The first result is highlighted as soon as there is one: Return adds it.
    .onChange(of: catalog.repos) { _, repos in
      if highlighted == nil { highlighted = RemoteRepo.ranked(repos, query: query).first?.id }
    }
  }

  @ViewBuilder
  private func status(catalog: RepoCatalog, count: Int) -> some View {
    if let cloning {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Cloning \(cloning.nameWithOwner)…")
      }
      .font(.callout)
    } else if let error {
      Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
    } else if let failure = catalog.error {
      HStack {
        Text(failure).font(.callout).foregroundStyle(.red).textSelection(.enabled)
        Button("Try Again") { catalog.loadIfNeeded() }
      }
    } else {
      Text("\(count) repositories\(catalog.loading ? " · loading more…" : "")")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private func current(in results: [RemoteRepo]) -> RemoteRepo? {
    results.first { $0.id == highlighted } ?? results.first
  }

  private func move(_ step: Int, in results: [RemoteRepo]) {
    guard !results.isEmpty else { return }
    let index = results.firstIndex { $0.id == highlighted } ?? (step > 0 ? -1 : results.count)
    highlighted = results[min(max(index + step, 0), results.count - 1)].id
  }

  private func add(_ repo: RemoteRepo) {
    guard cloning == nil else { return }
    cloning = repo
    error = nil
    Task {
      do {
        try await store.addRemote(repo)
        dismiss()
      } catch {
        self.error = error.localizedDescription
      }
      cloning = nil
    }
  }
}

private struct RemoteRepoRow: View {
  let repo: RemoteRepo

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Text(repo.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
          .layoutPriority(1)
        if repo.isPrivate {
          Octicon(.lock, size: 10).foregroundStyle(.secondary)
        }
        Text(repo.nameWithOwner).font(.caption).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle)
      }
      if let description = repo.description, !description.isEmpty {
        Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
    }
    .padding(.vertical, 2)
  }
}
