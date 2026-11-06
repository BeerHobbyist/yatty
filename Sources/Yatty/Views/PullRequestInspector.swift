import SwiftUI

/// The pull request of the worktree on screen: merge status, reviews,
/// checks, labels, description and comments — agentree's PR panel.
struct PullRequestInspector: View {
  let worktree: Worktree
  @Environment(AppStore.self) private var store
  @Environment(\.openURL) private var openURL

  var body: some View {
    if let badge = store.pullRequests.badge(for: worktree), let repo = store.repo(of: worktree) {
      let details = store.pullRequests.details[worktree.id]
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          header(badge, details)
          if let details {
            mergeSection(details)
            reviewsSection(details)
            checksSection(details)
            if !details.labels.isEmpty { labelsSection(details) }
            if !details.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { descriptionSection(details) }
            commentsSection(details)
          } else if store.pullRequests.detailsFailed.contains(worktree.id) {
            Text("Couldn't load the pull request.").foregroundStyle(.secondary)
          } else {
            ProgressView().controlSize(.small)
          }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .safeAreaInset(edge: .bottom) { footer(badge) }
      .task(id: worktree.id) {
        // Fresh while it's on screen: now, then every 30 seconds.
        while !Task.isCancelled {
          if NSApp.isActive || Snapshot.isActive { store.pullRequests.refreshDetails(for: worktree, in: repo) }
          try? await Task.sleep(for: .seconds(30))
        }
      }
    } else {
      ContentUnavailableView(
        "No Pull Request", systemImage: "arrow.triangle.pull",
        description: Text("\(store.label(for: worktree)) has no open pull request."))
    }
  }

  // MARK: Sections

  private func header(_ badge: BranchPullRequest, _ details: PullRequestDetails?) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text("#\(badge.number)").font(.headline.monospacedDigit())
        stateChip(details, badge: badge)
      }
      Button {
        if let url = URL(string: details?.url ?? badge.url) { openURL(url) }
      } label: {
        Text(details?.title ?? badge.title).font(.title3.weight(.semibold)).multilineTextAlignment(.leading)
      }
      .buttonStyle(.plain)
      .help("Open on GitHub")
      if let details {
        Text("\(details.author?.login ?? "?") · \(details.baseRefName) ← \(details.headRefName)")
          .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        HStack(spacing: 8) {
          Text("+\(details.additions)").foregroundStyle(.green)
          Text("−\(details.deletions)").foregroundStyle(.red)
          Text("\(details.changedFiles) file\(details.changedFiles == 1 ? "" : "s")").foregroundStyle(.secondary)
        }
        .font(.callout.monospacedDigit())
      }
    }
  }

  private func stateChip(_ details: PullRequestDetails?, badge: BranchPullRequest) -> some View {
    let (label, color): (String, Color) =
      if badge.merged || details?.state == "MERGED" { ("Merged", .purple) }
      else if details?.state == "CLOSED" { ("Closed", .red) }
      else if badge.isDraft || details?.isDraft == true { ("Draft", .secondary) }
      else { ("Open", .green) }
    return Text(label).font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
      .background(Capsule().fill(color.opacity(0.18))).foregroundStyle(color)
  }

  private func mergeSection(_ details: PullRequestDetails) -> some View {
    let status = PullRequests.mergeStatus(details)
    return section("Merge", summary: status.label) {
      HStack {
        Text(status.label).foregroundStyle(color(status.tone))
        Spacer()
        if details.state == "OPEN" {
          Button("Merge…") { store.mergingWorktree = worktree }
        }
      }
    }
  }

  private func reviewsSection(_ details: PullRequestDetails) -> some View {
    let decision: String =
      switch details.reviewDecision {
      case "APPROVED": "✓"
      case "CHANGES_REQUESTED": "✗"
      case "REVIEW_REQUIRED": "◌"
      default: ""
      }
    return section("Reviews", summary: decision) {
      if details.latestReviews.isEmpty && details.reviewRequests.isEmpty {
        Text("No reviews yet.").foregroundStyle(.secondary)
      }
      ForEach(Array(details.latestReviews.enumerated()), id: \.offset) { _, review in
        HStack(spacing: 6) {
          Text(verdict(review.state)).foregroundStyle(verdictColor(review.state))
          Text(review.author?.login ?? "?")
          Spacer()
          Text(PullRequests.relativeTime(review.submittedAt ?? "")).foregroundStyle(.secondary).font(.caption)
        }
      }
      ForEach(details.reviewRequests, id: \.displayName) { request in
        HStack(spacing: 6) {
          Text("◌").foregroundStyle(.secondary)
          Text(request.displayName).foregroundStyle(.secondary)
          Text("requested").font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  private func checksSection(_ details: PullRequestDetails) -> some View {
    let checks = details.statusCheckRollup.map { ($0, PullRequests.checkState($0)) }
    let order: [CheckState] = [.fail, .pending, .pass, .skipped]
    let sorted = checks.sorted { order.firstIndex(of: $0.1)! < order.firstIndex(of: $1.1)! }
    let counts = order.compactMap { state -> String? in
      let n = checks.filter { $0.1 == state }.count
      return n == 0 ? nil : "\(n) \(state == .pass ? "passed" : state == .fail ? "failed" : state == .pending ? "running" : "skipped")"
    }
    return section("Checks", summary: counts.joined(separator: ", ")) {
      if checks.isEmpty { Text("No checks.").foregroundStyle(.secondary) }
      ForEach(Array(sorted.enumerated()), id: \.offset) { _, entry in
        Button {
          if let link = entry.0.link { openURL(link) }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: checkSymbol(entry.1)).foregroundStyle(checkColor(entry.1))
            Text(entry.0.displayName).lineLimit(1).truncationMode(.middle)
            Spacer()
          }
        }
        .buttonStyle(.plain)
        .disabled(entry.0.link == nil)
      }
    }
  }

  private func labelsSection(_ details: PullRequestDetails) -> some View {
    section("Labels", summary: details.labels.map(\.name).joined(separator: ", ")) {
      HStack {
        ForEach(details.labels, id: \.name) { label in
          Text(label.name).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill((Color(hex: label.color) ?? .secondary).opacity(0.3)))
        }
      }
    }
  }

  private func descriptionSection(_ details: PullRequestDetails) -> some View {
    section("Description", summary: "") {
      Text(markdown(details.body)).textSelection(.enabled)
    }
  }

  private struct CommentItem {
    var author: String
    var body: String
    var date: String
    var location: String?
    var url: String?
  }

  private func commentsSection(_ details: PullRequestDetails) -> some View {
    var items = details.comments.map {
      CommentItem(author: $0.author?.login ?? "?", body: $0.body, date: $0.createdAt, location: nil, url: $0.url)
    }
    items += details.reviews.filter { !($0.body ?? "").isEmpty }.map {
      CommentItem(author: $0.author?.login ?? "?", body: $0.body ?? "", date: $0.submittedAt ?? "", location: verdict($0.state), url: nil)
    }
    items += (store.pullRequests.inlineComments[worktree.id] ?? []).map {
      CommentItem(
        author: $0.user?.login ?? "?", body: $0.body, date: $0.created_at,
        location: "\($0.path):\($0.line ?? $0.original_line ?? 0)", url: $0.html_url)
    }
    items.sort { $0.date > $1.date }
    return section("Comments", summary: items.isEmpty ? "" : "\(items.count)") {
      if items.isEmpty { Text("No comments.").foregroundStyle(.secondary) }
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(item.author).fontWeight(.medium)
            if let location = item.location { Text(location).font(.caption.monospaced()).foregroundStyle(.secondary) }
            Spacer()
            Text(PullRequests.relativeTime(item.date)).font(.caption).foregroundStyle(.secondary)
          }
          Text(markdown(item.body)).textSelection(.enabled).lineLimit(8)
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let url = item.url.flatMap(URL.init(string:)) { openURL(url) } }
      }
    }
  }

  private func footer(_ badge: BranchPullRequest) -> some View {
    let refreshed = store.pullRequests.detailsRefreshed[worktree.id]
    let state =
      store.pullRequests.refreshingDetails.contains(worktree.id) ? "↻ refreshing…"
      : store.pullRequests.detailsFailed.contains(worktree.id) ? "↻ failed"
      : refreshed.map { "↻ " + PullRequests.relativeTime(ISO8601DateFormatter().string(from: $0)) } ?? ""
    return HStack {
      Text(state).font(.caption).foregroundStyle(.secondary)
      Spacer()
      Button("Refresh") { store.refreshPullRequests() }.help("Refresh (⌘R)")
      Button("Open") { if let url = URL(string: badge.url) { openURL(url) } }
    }
    .buttonStyle(.borderless)
    .font(.callout)
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(.bar)
  }

  // MARK: Pieces

  /// A section whose title folds it; folded ones keep their summary.
  private func section<Content: View>(
    _ title: String, summary: String, @ViewBuilder content: () -> Content
  ) -> some View {
    let folded = store.foldedSections.contains(title)
    return VStack(alignment: .leading, spacing: 6) {
      Button {
        store.toggleSection(title)
      } label: {
        HStack(spacing: 4) {
          Image(systemName: folded ? "chevron.right" : "chevron.down").font(.caption2)
          Text(title).font(.headline)
          if folded || ["Reviews", "Checks", "Comments"].contains(title) {
            Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer()
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if !folded {
        VStack(alignment: .leading, spacing: 6) { content() }.padding(.leading, 14)
      }
    }
  }

  private func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }

  private func verdict(_ state: String) -> String {
    switch state {
    case "APPROVED": "✓"
    case "CHANGES_REQUESTED": "✗"
    case "COMMENTED": "●"
    case "DISMISSED": "–"
    default: "◌"
    }
  }

  private func verdictColor(_ state: String) -> Color {
    switch state {
    case "APPROVED": .green
    case "CHANGES_REQUESTED": .red
    default: .secondary
    }
  }

  private func checkSymbol(_ state: CheckState) -> String {
    switch state {
    case .pass: "checkmark.circle.fill"
    case .fail: "xmark.circle.fill"
    case .pending: "clock"
    case .skipped: "minus.circle"
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
