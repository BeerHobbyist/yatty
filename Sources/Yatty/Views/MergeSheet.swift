import SwiftUI

/// Merges the worktree's pull request — or sets it to merge once it's ready —
/// with a method the repository allows, after a confirm step, pinned to the
/// head commit on screen. agentree's merge dialog.
struct MergeSheet: View {
  let worktree: Worktree
  /// Picked already (the PR panel's button): start at the confirm step.
  var preset: MergeMethod?
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss

  private enum Step: Equatable {
    case choosing, confirming, merging
    case done(String)
    case failed(String)
  }

  @State private var settings: MergeSettings?
  @State private var settingsError: String?
  @State private var method: MergeMethod = .squash
  @State private var step: Step = .choosing

  var body: some View {
    let details = store.pullRequests.details[worktree.id]
    VStack(alignment: .leading, spacing: 14) {
      if let details {
        Text("Merge #\(details.number)").font(.headline)
        Text(details.title).foregroundStyle(.secondary).lineLimit(2)
        if let settings {
          content(details, settings: settings, options: PullRequests.mergeOptions(details, settings: settings))
        } else if let settingsError {
          Text(settingsError).foregroundStyle(.red).textSelection(.enabled)
          buttons { Button("Close", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction) }
        } else {
          ProgressView().controlSize(.small)
        }
      } else {
        Text("The pull request isn't loaded yet.").foregroundStyle(.secondary)
        buttons { Button("Close", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction) }
      }
    }
    .padding(20)
    .frame(width: 460)
    .task { await loadSettings() }
  }

  @ViewBuilder
  private func content(
    _ details: PullRequestDetails, settings: MergeSettings, options: (now: Bool, auto: Bool, reason: String?)
  ) -> some View {
    switch step {
    case .choosing:
      if options.now || options.auto {
        if options.auto, let reason = options.reason {
          Text("\(reason) — it will merge once it's ready.").font(.callout)
        }
        Picker("Method", selection: $method) {
          ForEach(methods(settings), id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.radioGroup)
        buttons {
          Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
          Button("Continue") { step = .confirming }.keyboardShortcut(.defaultAction)
        }
      } else {
        Text(options.reason ?? "It can't be merged from here.").font(.callout)
        buttons { Button("Close", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction) }
      }
    case .confirming:
      Text(
        options.auto
          ? "Set #\(details.number) to \(method.title.lowercased()) into \(details.baseRefName) once it's ready?"
          : "\(method.title) #\(details.number) into \(details.baseRefName)?"
      )
      .font(.callout)
      Text("Pinned to \(details.headRefOid.prefix(7)): a push you haven't seen here won't be merged with it.")
        .font(.caption).foregroundStyle(.secondary)
      buttons {
        Button("Back") { step = .choosing }.keyboardShortcut(.cancelAction)
        Button(options.auto ? "Enable Auto-Merge" : "Merge") { merge(details, auto: options.auto) }
          .keyboardShortcut(.defaultAction)
      }
    case .merging:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Merging…")
      }
    case .done(let message):
      Text(message).font(.callout)
      buttons {
        if !worktree.isMain, let repo = store.repo(of: worktree) {
          Button("Close Worktree…") {
            dismiss()
            store.pendingClose = PendingClose(repo: repo, worktree: worktree)
          }
        }
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    case .failed(let message):
      Text(message).foregroundStyle(.red).textSelection(.enabled)
      buttons {
        Button("Back") { step = .choosing }
        Button("Close", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }
  }

  private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    HStack {
      Spacer()
      content()
    }
  }

  /// The repository's methods, the one used last first.
  private func methods(_ settings: MergeSettings) -> [MergeMethod] {
    guard let last = store.mergeMethod, settings.methods.contains(last) else { return settings.methods }
    return [last] + settings.methods.filter { $0 != last }
  }

  private func loadSettings() async {
    guard let nameWithOwner = store.repo(of: worktree)?.nameWithOwner else {
      settingsError = "This repository has no GitHub remote."
      return
    }
    do {
      let loaded = try await GitHub.mergeSettings(nameWithOwner)
      settings = loaded
      if let preset, loaded.methods.contains(preset) {
        method = preset
        step = .confirming
      } else {
        method = methods(loaded).first ?? .squash
      }
    } catch {
      settingsError = error.localizedDescription
    }
  }

  private func merge(_ details: PullRequestDetails, auto: Bool) {
    guard let repo = store.repo(of: worktree), let nameWithOwner = repo.nameWithOwner else { return }
    step = .merging
    Task {
      do {
        try await GitHub.merge(
          number: details.number, in: nameWithOwner, method: method, auto: auto, headSha: details.headRefOid)
        store.mergeMethod = method
        store.saveState()
        store.pullRequests.invalidate(repo)
        step = .done(auto ? "#\(details.number) will merge once it's ready." : "#\(details.number) is merged.")
      } catch {
        step = .failed(error.localizedDescription)
      }
    }
  }
}
