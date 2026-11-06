import SwiftUI

/// A new worktree on a new branch, an existing branch, or an open pull
/// request, as agentree's add-worktree dialog offers.
struct NewWorktreeSheet: View {
  let repo: Repo
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss

  enum Mode: String, CaseIterable, Identifiable {
    case newBranch = "New Branch"
    case existingBranch = "Existing Branch"
    case pullRequest = "Pull Request"
    var id: String { rawValue }
  }

  @State private var mode = Self.initialMode
  @State private var branch = ""
  @State private var base = ""
  @State private var branches = Branches(current: nil, local: [], remote: [])
  @State private var remotes: [String] = []
  @State private var filter = ""
  @State private var pickedBranch: String?
  @State private var pullRequests: [OpenPullRequest] = []
  @State private var pullRequestsLoading = false
  @State private var pullRequestError: String?
  @State private var pickedPullRequest: Int?
  @State private var error: String?
  @State private var busy = false

  private static var initialMode: Mode {
    switch Snapshot.sheet {
    case "new-worktree-pr": .pullRequest
    case "new-worktree-existing": .existingBranch
    default: .newBranch
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("New Worktree in \(repo.name)").font(.headline)
      Picker("Start from", selection: $mode) {
        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      Group {
        switch mode {
        case .newBranch: newBranchForm
        case .existingBranch: existingBranchList
        case .pullRequest: pullRequestList
        }
      }
      .frame(height: 260, alignment: .top)

      if let error {
        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Create") { create() }
          .keyboardShortcut(.defaultAction)
          .disabled(choice == nil || busy)
      }
    }
    .padding(20)
    .frame(width: 520)
    .task { await load() }
  }

  // MARK: New branch

  private var newBranchForm: some View {
    Form {
      TextField("Branch", text: $branch, prompt: Text("feature/login"))
      HStack {
        TextField("Based on", text: $base, prompt: Text("HEAD"))
        Menu {
          Section("Local") {
            ForEach(branches.local, id: \.self) { name in Button(name) { base = name } }
          }
          Section("Remote") {
            ForEach(branches.remote, id: \.self) { name in Button(name) { base = name } }
          }
        } label: {
          Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Pick a branch")
      }
    }
  }

  // MARK: Existing branch

  private struct BranchOption: Identifiable {
    let id: String
    let choice: NewWorktreeChoice
    let isRemote: Bool
  }

  /// Branches that don't have a worktree: local ones, then remote ones with
  /// no local branch of the same name.
  private var branchOptions: [BranchOption] {
    let checkedOut = Set((store.worktrees[repo.id] ?? []).compactMap(\.branch))
    let local = branches.local.filter { !checkedOut.contains($0) }.map {
      BranchOption(id: $0, choice: .existingBranch($0), isRemote: false)
    }
    let remote: [BranchOption] = branches.remote.compactMap { full in
      guard let remote = remotes.first(where: { full.hasPrefix($0 + "/") }) else { return nil }
      let name = String(full.dropFirst(remote.count + 1))
      guard !checkedOut.contains(name), !branches.local.contains(name) else { return nil }
      return BranchOption(id: full, choice: .remoteBranch(remote: remote, branch: name), isRemote: true)
    }
    let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
    let all = local + remote
    return needle.isEmpty ? all : all.filter { $0.id.lowercased().contains(needle) }
  }

  private var existingBranchList: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Filter branches", text: $filter).textFieldStyle(.roundedBorder)
      let options = branchOptions
      if options.isEmpty {
        emptyNote("Every branch has a worktree already.")
      } else {
        List(options, selection: $pickedBranch) { option in
          HStack {
            Text(option.id).lineLimit(1).truncationMode(.middle)
            if option.isRemote {
              Text("remote").font(.caption).foregroundStyle(.secondary)
            }
          }
          .tag(option.id)
          .simultaneousGesture(TapGesture(count: 2).onEnded { create() })
        }
      }
    }
  }

  // MARK: Pull request

  /// Open pull requests whose branch has no worktree yet.
  private var visiblePullRequests: [OpenPullRequest] {
    let checkedOut = Set((store.worktrees[repo.id] ?? []).compactMap(\.branch))
    let local = Set(branches.local)
    return pullRequests.filter {
      !checkedOut.contains(NewWorktreeChoice.branchName(for: $0, existing: local))
    }
  }

  @ViewBuilder
  private var pullRequestList: some View {
    if repo.nameWithOwner == nil {
      emptyNote("This repository has no GitHub remote, so it has no pull requests to start from.")
    } else if pullRequestsLoading {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Loading pull requests…").foregroundStyle(.secondary)
      }
    } else if let pullRequestError {
      VStack(alignment: .leading, spacing: 8) {
        Text(pullRequestError).font(.callout).foregroundStyle(.red).textSelection(.enabled)
        Button("Try Again") { Task { await loadPullRequests() } }
      }
    } else if visiblePullRequests.isEmpty {
      emptyNote(pullRequests.isEmpty ? "No open pull requests." : "Every open pull request has a worktree already.")
    } else {
      List(visiblePullRequests, selection: $pickedPullRequest) { pr in
        VStack(alignment: .leading, spacing: 2) {
          Text("#\(pr.number) \(pr.title)").lineLimit(1)
          Text("\(pr.author.login) · \(pr.headRefName)\(pr.isCrossRepository ? " · fork" : "")")
            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .tag(pr.number)
        .simultaneousGesture(TapGesture(count: 2).onEnded { create() })
      }
    }
  }

  private func emptyNote(_ text: String) -> some View {
    Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: Creating

  private var choice: NewWorktreeChoice? {
    switch mode {
    case .newBranch:
      let name = trimmed(branch)
      return name.isEmpty ? nil : .newBranch(name: name, base: trimmed(base).isEmpty ? "HEAD" : trimmed(base))
    case .existingBranch:
      return branchOptions.first { $0.id == pickedBranch }?.choice
    case .pullRequest:
      return visiblePullRequests.first { $0.number == pickedPullRequest }.map { .pullRequest($0) }
    }
  }

  private func load() async {
    base = await Git.defaultBase(root: repo.path)
    branches = (try? await Git.listBranches(root: repo.path)) ?? branches
    remotes = await Git.remotes(root: repo.path)
    await loadPullRequests()
    if pickedPullRequest == nil { pickedPullRequest = visiblePullRequests.first?.number }
    if pickedBranch == nil { pickedBranch = branchOptions.first?.id }
  }

  private func loadPullRequests() async {
    guard let nameWithOwner = repo.nameWithOwner else { return }
    pullRequestsLoading = true
    pullRequestError = nil
    defer { pullRequestsLoading = false }
    do {
      pullRequests = try await GitHub.openPullRequests(nameWithOwner)
    } catch {
      pullRequestError = error.localizedDescription
    }
  }

  private func create() {
    guard let choice, !busy else { return }
    busy = true
    error = nil
    Task {
      do {
        try await store.createWorktree(in: repo, choice: choice)
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
