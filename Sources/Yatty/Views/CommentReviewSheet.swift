import AppKit
import SwiftUI

/// The pull request's comments on GitHub, to pick which go to the agent. The
/// picked ones are copied as a prompt that says they come from the review
/// on GitHub.
struct CommentReviewSheet: View {
  let worktree: Worktree
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var picked: Set<String> = []
  /// Until the user picks, the picks follow the defaults as comments arrive;
  /// after, only comments not seen before get theirs.
  @State private var userPicked = false
  @State private var seen: Set<String> = []
  /// The sheet asks GitHub again on opening: until that answer, what's
  /// cached may be stale, and isn't copied.
  @State private var openedAt = Date()
  /// Nothing to ask GitHub (no repository slug, no pull request any more).
  @State private var cannotRefresh = false
  /// Threads shown or hidden against their default: resolved ones start hidden.
  @State private var toggledThreads: Set<String> = []
  @State private var copied = false

  var body: some View {
    let details = store.pullRequests.details[worktree.id]
    let items = details.map {
      PullRequestConversation.all(details: $0, threads: store.pullRequests.reviewThreads[worktree.id] ?? [])
    } ?? []
    let pullRequests = store.pullRequests
    let settled =
      cannotRefresh || (pullRequests.detailsRefreshed[worktree.id] ?? .distantPast) >= openedAt
      || (!pullRequests.refreshingDetails.contains(worktree.id) && pullRequests.detailsFailed.contains(worktree.id))
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Review Comments").font(.headline)
        if let details {
          HStack(spacing: 4) {
            Octicon(.gitPullRequest, size: 12)
            Text("#\(details.number) \(details.title)").lineLimit(1).truncationMode(.tail)
          }
          .foregroundStyle(.secondary)
        }
        Text("Pick what your agent should work through. The prompt says these come from the review on GitHub.")
          .font(.callout).foregroundStyle(.secondary)
      }

      Group {
        if details == nil {
          if store.pullRequests.detailsFailed.contains(worktree.id) {
            Text("Couldn't load the pull request.").foregroundStyle(.secondary)
          } else {
            ProgressView().controlSize(.small)
          }
        } else if items.isEmpty {
          Text("No comments on this pull request.").foregroundStyle(.secondary)
        } else {
          List(items) { item in
            row(item)
          }
          .listStyle(.inset)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      HStack {
        Text("\(items.filter { picked.contains($0.id) }.count) of \(items.count) picked")
          .font(.callout).foregroundStyle(.secondary)
        if !settled && details != nil { ProgressView().controlSize(.small).help("Asking GitHub for the latest") }
        Button("All") {
          userPicked = true
          picked = Set(items.map(\.id))
        }
        .disabled(items.isEmpty)
        Button("None") {
          userPicked = true
          picked = []
        }
        .disabled(picked.isEmpty)
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(copied ? "Copied" : "Copy Prompt") { copy(items, details) }
          .keyboardShortcut(.defaultAction)
          .disabled(details == nil || !settled || !items.contains { picked.contains($0.id) } || copied)
      }
    }
    .padding(20)
    .frame(width: 640, height: 620)
    .task {
      // Fresh: the inspector may never have loaded them.
      if let repo = store.repo(of: worktree), repo.nameWithOwner != nil, store.pullRequests.badge(for: worktree) != nil {
        store.pullRequests.refreshDetails(for: worktree, in: repo)
      } else {
        cannotRefresh = true
      }
    }
    .onChange(of: items, initial: true) { _, items in
      guard let details else { return }
      let author = details.author?.login
      if userPicked {
        picked.formUnion(items.filter { !seen.contains($0.id) && $0.pickedByDefault(author: author) }.map(\.id))
      } else {
        picked = Set(items.filter { $0.pickedByDefault(author: author) }.map(\.id))
      }
      seen.formUnion(items.map(\.id))
    }
  }

  private func row(_ item: PullRequestConversation) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Toggle("", isOn: Binding(
        get: { picked.contains(item.id) },
        set: {
          userPicked = true
          if $0 { picked.insert(item.id) } else { picked.remove(item.id) }
        }
      ))
      .toggleStyle(.checkbox)
      .labelsHidden()
      switch item {
      case .note(let note):
        PullRequestNoteView(
          author: note.author, review: note.review, date: note.date, text: note.body, url: note.url, maxHeight: 120)
      case .thread(let thread):
        ReviewThreadView(thread: thread, open: thread.isResolved == toggledThreads.contains(thread.id)) {
          if toggledThreads.remove(thread.id) == nil { toggledThreads.insert(thread.id) }
        }
      }
    }
    .padding(.vertical, 4)
  }

  /// The picked comments on the clipboard, as `ReviewPrompt` writes them.
  private func copy(_ items: [PullRequestConversation], _ details: PullRequestDetails?) {
    guard let details else { return }
    let prompt = ReviewPrompt.make(details: details, picked: items.filter { picked.contains($0.id) })
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(prompt, forType: .string)
    copied = true
    Task {
      try? await Task.sleep(for: .milliseconds(600))
      dismiss()
    }
  }
}
