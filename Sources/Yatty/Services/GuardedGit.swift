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
  typealias Override = (key: String, value: String)

  private static let fixed: [Override] = [
    ("core.fsmonitor", "false"), ("core.hooksPath", "/dev/null"), ("diff.external", ""),
    ("core.quotePath", "false"), ("log.showSignature", "false"), ("diff.submodule", "short"),
    // No git process inside a submodule: it would read the submodule's own config.
    ("diff.ignoreSubmodules", "dirty"), ("submodule.recurse", "false"), ("status.submoduleSummary", "false"),
  ]

  /// What switches all of that off, plus the repository's own filters and
  /// config-defined hooks (`hook.<name>.command`, which core.hooksPath doesn't stop).
  static func overrides(filters: [String], hooks: [String]) -> [Override] {
    let off = filters.flatMap { name in
      [("clean", ""), ("smudge", ""), ("process", ""), ("required", "false")].map { ("filter.\(name).\($0.0)", $0.1) }
    }
    return fixed + off + hooks.map { ("hook.\($0).enabled", "false") }
  }

  /// The overrides as `GIT_CONFIG_COUNT`/`KEY_n`/`VALUE_n`, where a key may
  /// hold "=" (`-c` splits at the first one), plus no lazy fetch in a partial
  /// clone and no credential prompt.
  static func environment(_ overrides: [Override]) -> [String: String] {
    var env = ["GIT_NO_LAZY_FETCH": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_COUNT": String(overrides.count)]
    for (index, override) in overrides.enumerated() {
      env["GIT_CONFIG_KEY_\(index)"] = override.key
      env["GIT_CONFIG_VALUE_\(index)"] = override.value
    }
    return env
  }

  /// The filter drivers and hooks defined where an agent can write — the
  /// repository's config, its includes, the worktree's — from
  /// `git config --show-scope --includes -z --get-regexp '^(filter|hook)\.'`
  /// (scope NUL key LF value NUL). Global ones (Git LFS) stay: the user wrote those.
  static func repositoryConfig(_ config: String) -> (filters: [String], hooks: [String]) {
    var filters: [String] = []
    var hooks: [String] = []
    let fields = config.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    for index in stride(from: 0, to: fields.count - 1, by: 2) {
      let scope = fields[index]
      guard scope == "local" || scope == "worktree",
        let key = fields[index + 1].split(separator: "\n", maxSplits: 1).first.map(String.init)
      else { continue }
      if let name = subsection(of: key, in: "filter"), !filters.contains(name) { filters.append(name) }
      if let name = subsection(of: key, in: "hook"), !hooks.contains(name) { hooks.append(name) }
    }
    return (filters, hooks)
  }

  /// `name` in `section.name.variable`; nil for `section.variable` or an empty name.
  private static func subsection(of key: String, in section: String) -> String? {
    let prefix = section + "."
    guard key.hasPrefix(prefix), let dot = key.lastIndex(of: ".") else { return nil }
    let start = key.index(key.startIndex, offsetBy: prefix.count)
    guard start < dot else { return nil }
    return String(key[start..<dot])
  }

  /// The overrides for the repository at `dir`; reading config runs nothing.
  static func overrides(in dir: String) async -> [Override] {
    let config = await Run.run(
      "/usr/bin/env",
      ["git", "-C", dir, "config", "--show-scope", "--includes", "-z", "--get-regexp", "^(filter|hook)\\."],
      env: environment(fixed))
    let found = repositoryConfig(config.stdout)
    return overrides(filters: found.filters, hooks: found.hooks)
  }

  /// `git -C dir args…`, guarded; the result whatever its exit status.
  /// `overrides` saves reading them again in a batch of calls.
  static func result(_ args: [String], in dir: String, overrides: [Override]? = nil) async -> ProcessResult {
    let overrides = if let overrides { overrides } else { await self.overrides(in: dir) }
    return await Run.run("/usr/bin/env", ["git", "-C", dir] + args, env: environment(overrides))
  }

  /// `git -C dir args…`, guarded: stdout, or git's own message thrown.
  static func run(_ args: [String], in dir: String, overrides: [Override]? = nil) async throws -> String {
    let result = await result(args, in: dir, overrides: overrides)
    guard result.ok else {
      let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      throw GitError(message: message.isEmpty ? "git \(args.first ?? "") failed" : message)
    }
    return result.stdout
  }
}
