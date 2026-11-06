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

  /// A branch name as a directory name; the branch itself keeps its slashes.
  static func directoryName(for branch: String) -> String {
    var name = branch.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
    name = name.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
    name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return name.isEmpty ? "worktree" : name
  }
}
