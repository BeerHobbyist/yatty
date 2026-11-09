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

/// The text a `DiffWindow` shows: `git diff` through `GuardedGit`, since
/// the app reads it outside any sandbox while an agent may have written the
/// repository's config.
enum GitDiff {
  static let flags = ["--no-ext-diff", "--no-textconv", "--no-color", "-M", "--submodule=short", "--ignore-submodules=dirty"]
  /// A new file bigger than this isn't shown (it would be read whole).
  static let largestNewFile = 2_000_000

  /// The diff of `target` in `path`; for working changes, new files too
  /// (the first 200), which plain `git diff` leaves out.
  static func text(in path: String, target: DiffTarget) async throws -> String {
    let overrides = await GuardedGit.overrides(in: path)
    var text = try await GuardedGit.run(["diff"] + flags + target.args, in: path, overrides: overrides)
    guard target == .working else { return text }
    let untracked = try await GuardedGit.run(
      ["ls-files", "--others", "--exclude-standard", "-z"], in: path, overrides: overrides
    ).split(separator: "\0").map(String.init)
    for file in untracked.prefix(200) {
      let size = (try? FileManager.default.attributesOfItem(atPath: path + "/" + file)[.size] as? Int) ?? 0
      guard size <= largestNewFile else { continue }
      // `--no-index` exits 1 when the files differ, which they always do here.
      let result = await GuardedGit.result(
        ["diff", "--no-index"] + flags + ["--", "/dev/null", file], in: path, overrides: overrides)
      if result.status == 0 || result.status == 1 { text += result.stdout }
    }
    return text
  }
}
