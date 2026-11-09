import Foundation

/// What a unified diff says about its files.
enum UnifiedDiff {
  /// Each file's path, in the order the diff has them (diff2html draws them
  /// in that order too): the new path, the old one for a deletion.
  static func files(_ diff: String) -> [String] {
    struct File {
      var header: String
      var old: String?
      var new: String?
      var renamedTo: String?
    }
    var files: [String] = []
    var current: File?
    func finish() { if let current { files.append(path(of: current.header, old: current.old, new: current.new, renamedTo: current.renamedTo)) } }
    for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(raw)
      if line.hasPrefix("diff --git ") {
        finish()
        current = File(header: String(line.dropFirst("diff --git ".count)))
      } else if current != nil {
        if line.hasPrefix("--- ") {
          current?.old = name(line.dropFirst(4), prefix: "a/")
        } else if line.hasPrefix("+++ ") {
          current?.new = name(line.dropFirst(4), prefix: "b/")
        } else if line.hasPrefix("rename to ") {
          current?.renamedTo = unquote(String(line.dropFirst("rename to ".count)))
        }
      }
    }
    finish()
    return files
  }

  private static func path(of header: String, old: String?, new: String?, renamedTo: String?) -> String {
    if let new, new != "/dev/null" { return new }
    if let old, old != "/dev/null" { return old }
    if let renamedTo { return renamedTo }
    // `a/P b/P`: no ---/+++ lines (a binary file, a mode change).
    let count = header.count
    if count > 5, (count - 5) % 2 == 0 {
      let path = String(header.dropFirst(2).prefix((count - 5) / 2))
      if header == "a/\(path) b/\(path)" { return path }
    }
    if let range = header.range(of: " b/", options: .backwards) { return String(header[range.upperBound...]) }
    return header
  }

  /// `b/name` (git adds a tab after a name with spaces), maybe C-quoted.
  private static func name(_ text: Substring, prefix: String) -> String {
    var value = unquote(String(text))
    if value.hasSuffix("\t") { value.removeLast() }
    return value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
  }

  /// Git quotes names with control characters, quotes or backslashes.
  private static func unquote(_ text: String) -> String {
    let trimmed = text.hasSuffix("\t") ? String(text.dropLast()) : text
    guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else { return text }
    var out = ""
    var escaping = false
    for character in trimmed.dropFirst().dropLast() {
      if escaping {
        switch character {
        case "t": out.append("\t")
        case "n": out.append("\n")
        default: out.append(character)
        }
        escaping = false
      } else if character == "\\" {
        escaping = true
      } else {
        out.append(character)
      }
    }
    return out
  }
}

/// The prompt that hands the user's own diff comments to their agent. It
/// says whose they are — the user's review in Yatty, not GitHub's.
enum LocalReviewPrompt {
  static func make(target: DiffTarget, branch: String?, comments: [DiffComment]) -> String {
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
      + ", made in Yatty's diff view. They're mine, not comments from GitHub."
      + "\n\nWork through them: make the change each one asks for, or tell me why it shouldn't be made."
    let sorted = comments.sorted { ($0.path, $0.line, $0.side.rawValue) < ($1.path, $1.line, $1.side.rawValue) }
    for (index, comment) in sorted.enumerated() {
      out += "\n\n## \(index + 1). `\(comment.path):\(comment.line)`" + (comment.side == .old ? " (a removed line)" : "")
      out += comment.code.isEmpty ? "\n\n" : "\n\n```\n\(comment.code)\n```\n"
      out += comment.text
    }
    return out + "\n"
  }
}
