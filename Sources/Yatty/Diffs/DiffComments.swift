import Foundation

/// The prompt that hands the user's own diff comments to their agent. It
/// says whose they are — the user's review in Yatty, not GitHub's.
enum LocalReviewPrompt {
  static func make(target: DiffTarget, branch: String?, comments: [DiffComment], view: String = "diff view") -> String {
    let what: String =
      switch target {
      case .working: "the working changes"
      case .staged: "the staged changes"
      case .base(let base): "the changes vs \(base)"
      case .ref(let ref): "the changes vs \(ref)"
      case .range(let range): "the commits \(range)"
      }
    var out =
      "Below are comments from my own review of \(what) in this worktree"
      + (branch.map { " (\($0))" } ?? "")
      + ", made in Yatty's \(view). They're mine, not comments from GitHub."
      + "\n\nWork through them: make the change each one asks for, or tell me why it shouldn't be made."
    let sorted = comments.sorted { ($0.path, $0.line, $0.side.rawValue) < ($1.path, $1.line, $1.side.rawValue) }
    for (index, comment) in sorted.enumerated() {
      out += "\n\n## \(index + 1). `\(comment.path):\(comment.line)`" + (comment.side == .old ? " (a removed line)" : "")
      if comment.outdated { out += " (the line has changed since)" }
      out += comment.code.isEmpty ? "\n\n" : "\n\n```\n\(comment.code)\n```\n"
      out += comment.text
    }
    return out + "\n"
  }
}
