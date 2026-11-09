import Foundation

/// Read-only git for repositories an agent can write to, run by the app
/// outside any sandbox. Nothing the repository's own config names may run:
/// no fsmonitor, no hooks (an index refresh fires post-index-change), no
/// external diff or textconv, no clean filters it defines, no diffs inside
/// submodules (their own config), no signature checks (gpg.program), and no
/// lazy fetch in a partial clone (its ssh command or credential helper).
///
/// Writes (worktree add, fetch) keep plain `Git.run`: they need the user's
/// hooks and filters, LFS included.
enum GuardedGit {
  static let environment = ["GIT_NO_LAZY_FETCH": "1", "GIT_TERMINAL_PROMPT": "0"]

  private static let settings = [
    "core.fsmonitor=false", "core.hooksPath=/dev/null", "diff.external=", "core.quotePath=false",
    "log.showSignature=false", "diff.submodule=short", "submodule.recurse=false", "status.submoduleSummary=false",
  ]

  /// `args` behind `-c` settings that switch all of that off, and the
  /// repository's own `filters`.
  static func arguments(_ args: [String], filters: [String]) -> [String] {
    let off = filters.flatMap { name in
      ["clean=", "smudge=", "process=", "required=false"].map { "filter.\(name).\($0)" }
    }
    return (settings + off).flatMap { ["-c", $0] } + args
  }

  /// The filter drivers defined where an agent can write — the repository's
  /// config, its includes, the worktree's — from
  /// `git config --show-scope --get-regexp ^filter\.`. Global ones (Git LFS)
  /// stay: the user wrote those.
  static func repositoryFilters(_ config: String) -> [String] {
    var names: [String] = []
    for line in config.split(separator: "\n") {
      let parts = line.split(separator: "\t", maxSplits: 1)
      guard parts.count == 2, parts[0] == "local" || parts[0] == "worktree",
        let key = parts[1].split(separator: " ", maxSplits: 1).first, key.hasPrefix("filter."),
        let dot = key.lastIndex(of: ".")
      else { continue }
      let name = String(key[key.index(key.startIndex, offsetBy: "filter.".count)..<dot])
      if !name.isEmpty, !names.contains(name) { names.append(name) }
    }
    return names
  }

  /// The repository's own filter drivers (see `repositoryFilters`); reading
  /// config runs nothing.
  static func filters(in dir: String) async -> [String] {
    let config = await Run.run(
      "/usr/bin/env",
      ["git", "-C", dir, "-c", "core.fsmonitor=false", "config", "--show-scope", "--includes", "--get-regexp", "^filter\\."],
      env: environment)
    return repositoryFilters(config.stdout)
  }

  /// `git -C dir args…`, guarded; the result whatever its exit status.
  /// `filters` saves asking for them again in a batch of calls.
  static func result(_ args: [String], in dir: String, filters: [String]? = nil) async -> ProcessResult {
    let filters = if let filters { filters } else { await self.filters(in: dir) }
    return await Run.run("/usr/bin/env", ["git", "-C", dir] + arguments(args, filters: filters), env: environment)
  }

  /// `git -C dir args…`, guarded: stdout, or git's own message thrown.
  static func run(_ args: [String], in dir: String, filters: [String]? = nil) async throws -> String {
    let result = await result(args, in: dir, filters: filters)
    guard result.ok else {
      let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      throw GitError(message: message.isEmpty ? "git \(args.first ?? "") failed" : message)
    }
    return result.stdout
  }
}
