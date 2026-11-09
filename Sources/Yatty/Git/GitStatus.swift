import Foundation

/// A worktree's uncommitted changes and its distance from its upstream.
struct GitStatus: Equatable, Sendable {
  /// Files with changes, untracked ones included.
  var changed = 0
  var added = 0
  var removed = 0
  var ahead = 0
  var behind = 0
}

extension Git {
  /// nil when git couldn't read the worktree at all.
  static func status(path: String) async -> GitStatus? {
    // Every few seconds, on a worktree an agent may have rigged: guarded.
    let filters = await GuardedGit.filters(in: path)
    guard let porcelain = try? await GuardedGit.run(["status", "--porcelain"], in: path, filters: filters)
    else { return nil }
    var status = GitStatus(changed: parsePorcelainCount(porcelain))
    if let numstat = try? await GuardedGit.run(
      ["diff", "--numstat", "--no-ext-diff", "--no-textconv", "--submodule=short", "HEAD"], in: path, filters: filters)
    {
      (status.added, status.removed) = parseNumstat(numstat)
    }
    // No upstream: nothing to be ahead of or behind.
    if let counts = try? await GuardedGit.run(
      ["rev-list", "--left-right", "--count", "@{upstream}...HEAD"], in: path, filters: filters)
    {
      (status.ahead, status.behind) = parseAheadBehind(counts)
    }
    return status
  }

  static func parsePorcelainCount(_ output: String) -> Int {
    output.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
  }

  /// Totals of `diff --numstat`; binary files (`-\t-`) count for nothing.
  static func parseNumstat(_ output: String) -> (added: Int, removed: Int) {
    var added = 0
    var removed = 0
    for line in output.split(separator: "\n") {
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard fields.count >= 2 else { continue }
      added += Int(fields[0]) ?? 0
      removed += Int(fields[1]) ?? 0
    }
    return (added, removed)
  }

  /// `rev-list --left-right --count @{upstream}...HEAD`: behind, then ahead.
  static func parseAheadBehind(_ output: String) -> (ahead: Int, behind: Int) {
    let fields = output.split(whereSeparator: \.isWhitespace)
    guard fields.count == 2, let behind = Int(fields[0]), let ahead = Int(fields[1]) else { return (0, 0) }
    return (ahead, behind)
  }
}

extension Git {
  /// `git merge-base --is-ancestor`: false on any error too.
  static func isAncestor(_ commit: String, of head: String, in path: String) async -> Bool {
    await GuardedGit.result(["merge-base", "--is-ancestor", commit, head], in: path).ok
  }
}
