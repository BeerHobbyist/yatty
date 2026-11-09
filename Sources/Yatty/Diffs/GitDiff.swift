import Foundation

/// A diff to show in a `DiffWindow`; restored with the window.
struct DiffRequest: Codable, Hashable, Sendable {
  var worktreePath: String
  var worktreeName: String
  var target: DiffTarget
}

/// How the diff window lays changes out.
enum DiffLayout: String, Codable, CaseIterable, Sendable {
  /// diff2html's names for them.
  case split = "side-by-side"
  case unified = "line-by-line"
}

/// The text a `DiffWindow` shows: `git diff`, run so that nothing in the
/// repository's config can run a program — a sandboxed agent can write that
/// config, and the app reads the diff outside the sandbox.
enum GitDiff {
  private static let guarded = ["-c", "core.fsmonitor=false", "-c", "diff.external="]
  private static let flags = ["--no-ext-diff", "--no-textconv", "--no-color", "-M"]

  static func arguments(_ args: [String]) -> [String] {
    guarded + ["diff"] + flags + args
  }

  /// A new, untracked file as an addition.
  static func untrackedArguments(_ file: String) -> [String] {
    guarded + ["diff", "--no-index"] + flags + ["--", "/dev/null", file]
  }

  /// The diff of `target` in `path`; for working changes, new files too
  /// (the first 200), which plain `git diff` leaves out.
  static func text(in path: String, target: DiffTarget) async throws -> String {
    var text = try await Git.run(arguments(target.args), in: path)
    guard target == .working else { return text }
    let untracked = try await Git.run(["ls-files", "--others", "--exclude-standard", "-z"], in: path)
      .split(separator: "\0").map(String.init)
    for file in untracked.prefix(200) {
      // `--no-index` exits 1 when the files differ, which they always do here.
      let result = await Run.run("/usr/bin/env", ["git", "-C", path] + untrackedArguments(file))
      if result.status == 0 || result.status == 1 { text += result.stdout }
    }
    return text
  }
}
