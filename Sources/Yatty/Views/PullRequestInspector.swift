import SwiftUI

/// The PR panel's tabs, under its header and merge box.
enum PullRequestTab: String, CaseIterable, Sendable {
  case conversation, checks, description

  var title: String {
    switch self {
    case .conversation: "Conversation"
    case .checks: "Checks"
    case .description: "Description"
    }
  }
}

/// The pull request of the worktree on screen. A header that stays put — the
/// pull request, and a merge box as GitHub shows one: reviews, checks,
/// conflicts, the merge button — over tabs for the conversation, the checks
/// and the description.
struct PullRequestInspector: View {
  let worktree: Worktree
  @Environment(AppStore.self) private var store
  @Environment(\.openURL) private var openURL
  /// Threads shown or hidden against their default: resolved ones start hidden.
  @State private var toggledThreads: Set<String> = []

  var body: some View {
    if let badge = store.pullRequests.badge(for: worktree), let repo = store.repo(of: worktree) {
      let details = store.pullRequests.details[worktree.id]
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 12) {
          header(badge, details)
          if let details {
            mergeBox(details, repo: repo)
            tabPicker(details)
          }
        }
        .padding(14)
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            if let details {
              switch tab {
              case .conversation: conversation(details)
              case .checks: checks(details, repo: repo)
              case .description: description(details)
              }
            } else if store.pullRequests.detailsFailed.contains(worktree.id) {
              Text("Couldn't load the pull request.").foregroundStyle(.secondary)
            } else {
              ProgressView().controlSize(.small)
            }
          }
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .task(id: worktree.id) {
        // Fresh while it's on screen: now, then every 30 seconds. Merge
        // settings alongside, until there are some.
        while !Task.isCancelled {
          if NSApp.isActive || Snapshot.isActive {
            store.pullRequests.refreshDetails(for: worktree, in: repo)
            store.pullRequests.ensureMergeSettings(for: repo)
          }
          try? await Task.sleep(for: .seconds(30))
        }
      }
    } else {
      ContentUnavailableView {
        Label {
          Text("No Pull Request")
        } icon: {
          Octicon(.gitPullRequest, size: 40)
        }
      } description: {
        Text("\(store.label(for: worktree)) has no open pull request.")
      }
    }
  }

  private var tab: PullRequestTab { store.prTabs[worktree.id] ?? Snapshot.prTab ?? .conversation }

  private func show(_ tab: PullRequestTab) { store.prTabs[worktree.id] = tab }

  // MARK: Header

  private func header(_ badge: BranchPullRequest, _ details: PullRequestDetails?) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        stateChip(details, badge: badge)
        Text("#\(badge.number)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        Spacer()
        TimelineView(.periodic(from: .now, by: 30)) { _ in
          Button {
            store.refreshPullRequests()
          } label: {
            HStack(spacing: 3) {
              if store.pullRequests.refreshingDetails.contains(worktree.id) {
                ProgressView().controlSize(.mini)
              } else {
                Image(systemName: "arrow.clockwise")
              }
              Text(refreshedLabel)
            }
            .font(.caption)
          }
          .buttonStyle(.borderless)
          .foregroundStyle(.secondary)
          .help("Refresh (⌘R)")
        }
        Button {
          if let url = URL(string: details?.url ?? badge.url) { openURL(url) }
        } label: {
          Image(systemName: "arrow.up.right.square")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Open on GitHub")
      }
      Button {
        if let url = URL(string: details?.url ?? badge.url) { openURL(url) }
      } label: {
        Text(details?.title ?? badge.title).font(.title3.weight(.semibold)).multilineTextAlignment(.leading)
      }
      .buttonStyle(.plain)
      .help("Open on GitHub")
      if let details {
        HStack(spacing: 5) {
          AvatarView(login: details.author?.login)
          Text(MergeBox.author(details)).lineLimit(1)
          Octicon(.gitBranch, size: 12).padding(.leading, 4)
          Text("\(details.baseRefName) ← \(details.headRefName)").lineLimit(1).truncationMode(.middle)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        HStack(spacing: 8) {
          Text("+\(details.additions)").foregroundStyle(.green)
          Text("−\(details.deletions)").foregroundStyle(.red)
          Text("\(details.changedFiles) file\(details.changedFiles == 1 ? "" : "s")").foregroundStyle(.secondary)
        }
        .font(.callout.monospacedDigit())
      }
    }
  }

  private var refreshedLabel: String {
    if store.pullRequests.detailsFailed.contains(worktree.id) { return "failed" }
    guard let refreshed = store.pullRequests.detailsRefreshed[worktree.id] else { return "" }
    return PullRequests.relativeTime(ISO8601DateFormatter().string(from: refreshed))
  }

  private func stateChip(_ details: PullRequestDetails?, badge: BranchPullRequest) -> some View {
    let (label, icon, color): (String, Octicon.Name, Color) =
      if badge.merged || details?.state == "MERGED" { ("Merged", .gitMerge, .purple) }
      else if details?.state == "CLOSED" { ("Closed", .gitPullRequestClosed, .red) }
      else if badge.isDraft || details?.isDraft == true { ("Draft", .gitPullRequestDraft, .secondary) }
      else { ("Open", .gitPullRequest, .green) }
    return HStack(spacing: 3) {
      Octicon(icon, size: 11)
      Text(label)
    }
    .font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
    .background(Capsule().fill(color.opacity(0.18))).foregroundStyle(color)
  }

  // MARK: Merge box

  @ViewBuilder private func mergeBox(_ details: PullRequestDetails, repo: Repo) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if let finished = MergeBox.finished(details) {
        HStack {
          line(finished)
          if details.state == "MERGED", !worktree.isMain {
            Button("Close Worktree…") { store.requestClose(worktree) }
          }
        }
        .padding(.vertical, 8)
      } else {
        Button {
          show(.conversation)
        } label: {
          HStack {
            line(MergeBox.reviews(details))
            reviewerAvatars(details)
          }
        }
        .buttonStyle(.plain)
        .help("Show the conversation")
        Divider()
        Button {
          show(.checks)
        } label: {
          line(MergeBox.checks(details))
        }
        .buttonStyle(.plain)
        .help("Show the checks")
        Divider()
        line(MergeBox.conflicts(details))
        Divider()
        mergeButton(details, repo: repo).padding(.vertical, 8)
      }
    }
    .padding(.horizontal, 10)
    .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.35)))
    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary))
  }

  private func line(_ line: MergeBoxLine) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      Circle().fill(color(line.tone)).frame(width: 7, height: 7)
      VStack(alignment: .leading, spacing: 1) {
        Text(line.verdict).fontWeight(.semibold)
        if !line.detail.isEmpty {
          Text(line.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 7)
    .contentShape(Rectangle())
  }

  private func reviewerAvatars(_ details: PullRequestDetails) -> some View {
    HStack(spacing: -4) {
      ForEach(details.latestReviews.prefix(4).indices, id: \.self) { index in
        AvatarView(login: details.latestReviews[index].author?.login, size: 18)
          .overlay(Circle().strokeBorder(.background, lineWidth: 1))
      }
    }
  }

  @ViewBuilder private func mergeButton(_ details: PullRequestDetails, repo: Repo) -> some View {
    let settings = store.pullRequests.mergeSettings[repo.id]
    let failed = store.pullRequests.mergeSettingsFailed.contains(repo.id)
    switch MergeBox.button(details, settings: settings, lastMethod: store.mergeMethod, settingsFailed: failed) {
    case .merge(let method):
      splitButton(method: method, auto: false, settings: settings, caption: PullRequests.mergeStatus(details).label)
    case .autoMerge(let method):
      splitButton(method: method, auto: true, settings: settings, caption: "Merges once it's ready")
    case .disabled(let reason):
      HStack {
        Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        Spacer()
        Button("Merge") {}.disabled(true)
      }
    }
  }

  /// Merges (or turns on auto-merge) with `method`; its arrow picks another.
  /// Either way the merge sheet asks to confirm first.
  private func splitButton(method: MergeMethod, auto: Bool, settings: MergeSettings?, caption: String) -> some View {
      HStack {
        Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        Spacer()
        Menu {
          ForEach(settings?.methods ?? [], id: \.self) { other in
            Button(other.title) { store.mergeRequest = MergeRequest(worktree: worktree, method: other) }
          }
        } label: {
          Text(auto ? "Enable Auto-Merge" : method.buttonTitle)
        } primaryAction: {
          store.mergeRequest = MergeRequest(worktree: worktree, method: method)
        }
        .fixedSize()
        .help(auto ? "GitHub merges it once reviews and required checks pass" : "Merge: \(method.title.lowercased())")
      }
  }

  // MARK: Tabs

  private func tabPicker(_ details: PullRequestDetails) -> some View {
    let conversations = PullRequestConversation.all(details: details, threads: threads)
    let failing = details.statusCheckRollup.filter { PullRequests.checkState($0) == .fail }.count
    return Picker("", selection: Binding(get: { tab }, set: { show($0) })) {
      Text(conversations.isEmpty ? "Conversation" : "Conversation \(conversations.reduce(0) { $0 + $1.commentCount })")
        .tag(PullRequestTab.conversation)
      // A native segmented control can't colour a dot; the merge box's
      // checks line carries the red.
      Text(failing > 0 ? "Checks ●" : "Checks").tag(PullRequestTab.checks)
      Text("Description").tag(PullRequestTab.description)
    }
    .pickerStyle(.segmented)
    .labelsHidden()
  }

  private var threads: [ReviewThread] { store.pullRequests.reviewThreads[worktree.id] ?? [] }

  @ViewBuilder private func conversation(_ details: PullRequestDetails) -> some View {
    let items = PullRequestConversation.all(details: details, threads: threads)
    if items.isEmpty {
      Text("No comments.").foregroundStyle(.secondary)
    } else {
      HStack {
        let unresolved = threads.filter { !$0.isResolved }.count
        let resolved = threads.count - unresolved
        if !threads.isEmpty {
          Text("\(unresolved) unresolved" + (resolved > 0 ? " · \(resolved) resolved" : ""))
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Review…") { store.reviewingComments = worktree }
          .help("Pick comments to hand to your agent")
      }
      ForEach(items) { item in
        switch item {
        case .note(let note):
          PullRequestNoteView(author: note.author, review: note.review, date: note.date, text: note.body, url: note.url)
        case .thread(let thread):
          ReviewThreadView(thread: thread, open: thread.isResolved == toggledThreads.contains(thread.id)) {
            if toggledThreads.remove(thread.id) == nil { toggledThreads.insert(thread.id) }
          }
        }
      }
    }
  }

  @ViewBuilder private func checks(_ details: PullRequestDetails, repo: Repo) -> some View {
    let order: [CheckState] = [.fail, .pending, .pass, .skipped]
    let checks = details.statusCheckRollup.map { ($0, PullRequests.checkState($0)) }
      .enumerated().sorted { (order.firstIndex(of: $0.element.1)!, $0.offset) < (order.firstIndex(of: $1.element.1)!, $1.offset) }
      .map(\.element)
    if checks.isEmpty { Text("No checks.").foregroundStyle(.secondary) }
    ForEach(Array(checks.enumerated()), id: \.offset) { _, entry in
      let (check, state) = entry
      HStack(spacing: 7) {
        Octicon(checkIcon(state)).foregroundStyle(checkColor(state))
        Button {
          if let link = check.link { openURL(link) }
        } label: {
          Text(check.displayName).lineLimit(1).truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .disabled(check.link == nil)
        .help(check.link == nil ? "" : "Open its log on GitHub")
        Spacer()
        if let duration = check.duration {
          Text(PullRequests.durationLabel(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        if state == .fail, let link = check.detailsUrl, let run = PullRequests.actionsRun(link) {
          Button {
            store.rerun(run, in: worktree)
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.borderless)
          .help("Re-run its failed jobs")
        }
      }
      .padding(.vertical, 2)
    }
  }

  @ViewBuilder private func description(_ details: PullRequestDetails) -> some View {
    let blocks = MarkdownBlock.parse(details.body)
    if blocks.isEmpty {
      Text("No description.").foregroundStyle(.secondary)
    } else {
      MarkdownText(blocks: blocks)
    }
    if !details.labels.isEmpty {
      HStack {
        ForEach(details.labels, id: \.name) { label in
          Text(label.name).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill((Color(hex: label.color) ?? .secondary).opacity(0.3)))
        }
      }
      .padding(.top, 6)
    }
  }

  // MARK: Pieces

  private func checkIcon(_ state: CheckState) -> Octicon.Name {
    switch state {
    case .pass: .checkCircleFill
    case .fail: .xCircleFill
    case .pending: .dotFill
    case .skipped: .skip
    }
  }

  private func checkColor(_ state: CheckState) -> Color {
    switch state {
    case .pass: .green
    case .fail: .red
    case .pending: .orange
    case .skipped: .secondary
    }
  }

  private func color(_ tone: Tone) -> Color {
    switch tone {
    case .good: .green
    case .warn: .orange
    case .bad: .red
    case .muted: .secondary
    case .merged: .purple
    }
  }
}

extension Color {
  /// `d73a4a`, as GitHub gives label colours.
  init?(hex: String?) {
    guard let hex, hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
    self.init(
      red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255)
  }
}
