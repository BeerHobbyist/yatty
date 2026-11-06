import Foundation

struct GitError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

enum Git {
  /// Runs `git -C dir args…`, returning stdout or throwing git's own message.
  @discardableResult
  static func run(_ args: [String], in dir: String) async throws -> String {
    let result = await Run.run("/usr/bin/env", ["git", "-C", dir] + args)
    guard result.ok else {
      let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      throw GitError(message: message.isEmpty ? "git \(args.first ?? "") failed" : message)
    }
    return result.stdout
  }

  /// The main working copy of the repository `dir` is in (also when `dir` is
  /// one of its worktrees).
  static func mainRoot(containing dir: String) async throws -> String {
    let top = try await run(["rev-parse", "--show-toplevel"], in: dir)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let worktrees = try await listWorktrees(root: top)
    return worktrees.first?.path ?? top
  }

  /// `git worktree list --porcelain`; the first entry is the main working copy.
  static func listWorktrees(root: String) async throws -> [Worktree] {
    let out = try await run(["worktree", "list", "--porcelain"], in: root)
    var worktrees: [Worktree] = []
    var path: String?
    var branch: String?
    var head: String?
    var bare = false

    func finish() {
      if let path, !bare {
        worktrees.append(Worktree(
          path: canonicalPath(path), branch: branch, head: head, isMain: worktrees.isEmpty))
      }
      path = nil
      branch = nil
      head = nil
      bare = false
    }

    for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("worktree ") {
        finish()
        path = String(line.dropFirst("worktree ".count))
      } else if line.hasPrefix("HEAD ") {
        head = String(line.dropFirst("HEAD ".count))
      } else if line.hasPrefix("branch ") {
        let ref = line.dropFirst("branch ".count)
        branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : String(ref)
      } else if line == "bare" {
        bare = true
      }
    }
    finish()
    return worktrees
  }

  /// What a new branch starts from: the remote's default branch, else HEAD.
  static func defaultBase(root: String) async -> String {
    let ref = try? await run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: root)
    let trimmed = ref?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? "HEAD" : trimmed
  }

  /// Creates `branch` from `base` in a new worktree at `path`. The branch never
  /// tracks its base: started from origin/main it would otherwise push to main.
  static func addWorktree(root: String, path: String, branch: String, base: String) async throws {
    try await run(["worktree", "add", "--no-track", path, "-b", branch, base], in: root)
  }

  /// Deletes a worktree's directory, uncommitted changes included. A path git
  /// no longer tracks is left alone.
  static func removeWorktree(root: String, path: String) async throws {
    let tracked = try await listWorktrees(root: root).contains { $0.path == canonicalPath(path) }
    guard tracked else { return }
    try await run(["worktree", "remove", "--force", path], in: root)
  }

  /// Keeps `.worktrees/` out of the main copy's status, through the local
  /// `info/exclude` rather than the tracked .gitignore. Git says where that
  /// file is: `.git` may be a file pointing elsewhere (submodules).
  static func ignoreWorktreesDir(root: String) async {
    guard let reported = try? await run(["rev-parse", "--git-path", "info/exclude"], in: root)
      .trimmingCharacters(in: .whitespacesAndNewlines), !reported.isEmpty
    else { return }
    let exclude = reported.hasPrefix("/")
      ? URL(fileURLWithPath: reported)
      : URL(fileURLWithPath: root).appendingPathComponent(reported)
    let current = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
    if current.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == ".worktrees/" }) {
      return
    }
    let prefix = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
    try? FileManager.default.createDirectory(
      at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? (current + prefix + ".worktrees/\n").write(to: exclude, atomically: true, encoding: .utf8)
  }

  // MARK: Branches

  static func listBranches(root: String) async throws -> Branches {
    let current = try? await run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: root)
    let refs = try await run(
      ["for-each-ref", "--sort=-committerdate", "--format=%(refname)", "refs/heads", "refs/remotes"], in: root)
    let trimmed = current?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return parseBranches(refs, current: trimmed.isEmpty ? nil : trimmed)
  }

  /// `for-each-ref` output as local and remote branch names. `origin/HEAD`
  /// only points at another remote branch, so it's left out.
  static func parseBranches(_ refs: String, current: String?) -> Branches {
    var branches = Branches(current: current, local: [], remote: [])
    for ref in refs.split(separator: "\n") {
      if ref.hasPrefix("refs/heads/") {
        branches.local.append(String(ref.dropFirst("refs/heads/".count)))
      } else if ref.hasPrefix("refs/remotes/"), !ref.hasSuffix("/HEAD") {
        branches.remote.append(String(ref.dropFirst("refs/remotes/".count)))
      }
    }
    return branches
  }

  /// Checks out an existing branch in a new worktree. A remote branch
  /// (`origin/x`) becomes a local `x` tracking it.
  static func addWorktree(root: String, path: String, existingBranch branch: String) async throws {
    let remotes = (try? await run(["remote"], in: root))?.split(separator: "\n").map(String.init) ?? []
    if let remote = remotes.first(where: { branch.hasPrefix($0 + "/") }) {
      let local = String(branch.dropFirst(remote.count + 1))
      try await run(["worktree", "add", "--track", "-b", local, path, branch], in: root)
    } else {
      try await run(["worktree", "add", path, branch], in: root)
    }
  }

  /// Fetches a pull request's head into local `branch` (created or moved).
  /// `refs/pull/<n>/head` works for pull requests from forks too.
  static func fetchPullRequest(root: String, number: Int, into branch: String) async throws {
    try await run(["fetch", "origin", "+refs/pull/\(number)/head:refs/heads/\(branch)"], in: root)
  }

  // MARK: Remotes

  /// `owner/name` of a GitHub remote URL, in any form git or gh writes it.
  static func slug(fromRemote url: String) -> String? {
    var rest = url.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefixes = ["git@github.com:", "https://github.com/", "http://github.com/", "ssh://git@github.com/"]
    guard let prefix = prefixes.first(where: { rest.lowercased().hasPrefix($0) }) else { return nil }
    rest = String(rest.dropFirst(prefix.count))
    while rest.hasSuffix("/") { rest.removeLast() }
    if rest.hasSuffix(".git") { rest.removeLast(4) }
    let parts = rest.split(separator: "/")
    guard parts.count == 2 else { return nil }
    return parts.joined(separator: "/")
  }

  static func remoteMatches(_ url: String, nameWithOwner: String) -> Bool {
    slug(fromRemote: url)?.lowercased() == nameWithOwner.lowercased()
  }

  /// The GitHub `owner/name` of the repository's `origin`, if it has one.
  static func remoteSlug(root: String) async -> String? {
    guard let url = try? await run(["remote", "get-url", "origin"], in: root) else { return nil }
    return slug(fromRemote: url)
  }

  /// A branch name as a directory name; the branch itself keeps its slashes.
  static func directoryName(for branch: String) -> String {
    var name = branch.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
    name = name.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
    name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return name.isEmpty ? "worktree" : name
  }
}

struct Branches: Equatable, Sendable {
  /// What the main copy has checked out; nil when detached.
  var current: String?
  /// Most recently committed first.
  var local: [String]
  /// `origin/main` and the like, most recently committed first.
  var remote: [String]
}
