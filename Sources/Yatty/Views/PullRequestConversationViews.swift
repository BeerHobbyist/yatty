import SwiftUI

/// How a review's state shows: GitHub's icon, its colour, its name.
enum ReviewVerdict {
  static func icon(_ state: String) -> Octicon.Name {
    switch state {
    case "APPROVED": .check
    case "CHANGES_REQUESTED": .fileDiff
    case "COMMENTED": .comment
    case "DISMISSED": .circleSlash
    default: .dotFill
    }
  }

  static func label(_ state: String) -> String {
    switch state {
    case "APPROVED": "Approved"
    case "CHANGES_REQUESTED": "Changes requested"
    case "COMMENTED": "Commented"
    case "DISMISSED": "Dismissed"
    default: "Pending"
    }
  }

  static func color(_ state: String) -> Color {
    switch state {
    case "APPROVED": .green
    case "CHANGES_REQUESTED": .red
    case "COMMENTED", "DISMISSED": .secondary
    default: .orange
    }
  }
}

/// One comment: who, when, and what, as markdown. A double-click opens it on GitHub.
struct PullRequestNoteView: View {
  let author: String
  /// The review's state, for a review's summary.
  var review: String?
  let date: String
  /// The comment, as markdown.
  let text: String
  var url: String?
  var maxHeight: CGFloat? = 160
  @Environment(\.openURL) private var openURL

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Text(author).fontWeight(.medium)
        if let review {
          Octicon(ReviewVerdict.icon(review), size: 12).foregroundStyle(ReviewVerdict.color(review))
            .help(ReviewVerdict.label(review))
        }
        Spacer()
        Text(PullRequests.relativeTime(date)).font(.caption).foregroundStyle(.secondary)
      }
      MarkdownText(text, maxHeight: maxHeight)
    }
    .padding(.leading, 8)
    .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { if let url = url.flatMap(URL.init(string:)) { openURL(url) } }
  }
}

/// A thread on the diff, under its file and line; its header folds it.
struct ReviewThreadView: View {
  let thread: ReviewThread
  let open: Bool
  let toggle: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button(action: toggle) {
        HStack(spacing: 5) {
          Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.secondary)
          Octicon(.fileDiff, size: 12).foregroundStyle(.secondary)
          Text(thread.location)
            .font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
          if thread.isOutdated { ConversationTag(text: "Outdated", color: .orange) }
          if thread.isResolved { ConversationTag(text: "Resolved", color: .purple) }
          Spacer(minLength: 0)
          if !open {
            Text("\(thread.comments.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(open ? "Hide this conversation" : "Show this conversation")
      if open {
        ForEach(Array(thread.comments.enumerated()), id: \.offset) { _, comment in
          PullRequestNoteView(author: comment.author, date: comment.createdAt, text: comment.body, url: comment.url)
        }
        .padding(.leading, 14)
      }
    }
  }
}

struct ConversationTag: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
      .background(Capsule().fill(color.opacity(0.18))).foregroundStyle(color)
  }
}
