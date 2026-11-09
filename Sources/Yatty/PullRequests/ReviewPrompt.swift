import Foundation

/// A comment on a pull request, or a review's summary.
struct PullRequestNote: Equatable, Sendable {
  var id: String
  var author: String
  var body: String
  var date: String
  var url: String?
  /// The review's state, for a review's summary.
  var review: String?
}

/// Something said on a pull request: a note, or a thread on its diff.
enum PullRequestConversation: Identifiable, Equatable, Sendable {
  case note(PullRequestNote)
  case thread(ReviewThread)

  var id: String {
    switch self {
    case .note(let note): note.id
    case .thread(let thread): thread.id
    }
  }

  var date: String {
    switch self {
    case .note(let note): note.date
    case .thread(let thread): thread.date
    }
  }

  var commentCount: Int {
    switch self {
    case .note: 1
    case .thread(let thread): thread.comments.count
    }
  }

  /// Everything said on the pull request, newest first.
  static func all(details: PullRequestDetails, threads: [ReviewThread]) -> [PullRequestConversation] {
    var items: [PullRequestConversation] = details.comments.enumerated().map { index, comment in
      .note(
        PullRequestNote(
          id: comment.url ?? "comment-\(index)", author: comment.author?.login ?? "?", body: comment.body,
          date: comment.createdAt, url: comment.url))
    }
    items += details.reviews.enumerated().filter { !($0.element.body ?? "").isEmpty }.map { index, review in
      .note(
        PullRequestNote(
          id: "review-\(index)-\(review.submittedAt ?? "")", author: review.author?.login ?? "?",
          body: review.body ?? "", date: review.submittedAt ?? "", review: review.state))
    }
    items += threads.map(PullRequestConversation.thread)
    return items.sorted { $0.date > $1.date }
  }

  /// Picked at first in the comment review: what's still open and isn't the
  /// pull request's author talking.
  func pickedByDefault(author: String?) -> Bool {
    switch self {
    case .thread(let thread): !thread.isResolved
    case .note(let note): note.author != author
    }
  }
}

/// The prompt that hands picked comments to an agent. It says where they
/// come from — the pull request's review on GitHub, not the user's own local
/// review — so the agent knows whose words they are.
enum ReviewPrompt {
  static func make(details: PullRequestDetails, picked: [PullRequestConversation]) -> String {
    let author = details.author?.login
    var out = """
      Below are comments from the review of pull request #\(details.number) "\(details.title)" on GitHub \
      (\(details.url)), \(details.headRefName) into \(details.baseRefName). Reviewers left them on GitHub; \
      they are not from a local review of mine.

      Work through them in this worktree: make the change each one asks for, or tell me why it shouldn't be made.
      """
    // Threads first, by file and line: they point at the code. Then the
    // rest, oldest first.
    let threads = picked.compactMap { if case .thread(let thread) = $0 { thread } else { nil } }
      .sorted { ($0.path, $0.line ?? 0) < ($1.path, $1.line ?? 0) }
    let notes = picked.compactMap { if case .note(let note) = $0 { note } else { nil } }
      .sorted { $0.date < $1.date }
    var number = 0
    for thread in threads {
      number += 1
      var state = [thread.isResolved ? "resolved on GitHub" : "unresolved"]
      if thread.onBase { state.append("on removed lines: the numbers are the base branch's") }
      if thread.isOutdated { state.append("outdated: the code has changed since") }
      out += "\n\n## \(number). Thread on `\(thread.location)` (\(state.joined(separator: "; ")))"
      for comment in thread.comments {
        out += "\n\n" + said(by: comment.author, author: author, date: comment.createdAt, body: comment.body)
      }
    }
    for note in notes {
      number += 1
      let what = note.review.map { "Review by \(note.author) (\(verdict($0)))" } ?? "Comment by \(note.author)"
      out += "\n\n## \(number). \(what)\n\n" + said(by: note.author, author: author, date: note.date, body: note.body)
    }
    return out + "\n"
  }

  private static func said(by who: String, author: String?, date: String, body: String) -> String {
    let role = who == author ? ", the pull request's author" : ""
    let day = date.prefix(10)
    let text = body.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return "**\(who)**\(role)\(day.isEmpty ? "" : " on \(day)"):\n\(text)"
  }

  private static func verdict(_ state: String) -> String {
    switch state {
    case "APPROVED": "approved"
    case "CHANGES_REQUESTED": "changes requested"
    case "DISMISSED": "dismissed"
    default: "commented"
    }
  }
}
