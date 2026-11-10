import Foundation

/// The code view's reads: files from the worktree, and git's view of them
/// through `GuardedGit` (the app reads outside any sandbox, and an agent may
/// have written the repository's config).
enum CodeSource {
  struct Unreadable: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
  }

  /// A file as the code view shows it: its text, and its diff against the
  /// base (none for a file git doesn't track, which is new as a whole).
  struct Loaded: Equatable, Sendable {
    var text: String
    var diff: String
    var untracked: Bool
  }

  /// Bigger files aren't shown: the page would read them whole.
  static let largest = 2_000_000

  /// `file` (relative to the worktree at `root`) and its diff against `rev`.
  static func load(_ file: String, in root: String, against rev: String) async throws -> Loaded {
    let url = try resolve(file, in: root)
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes?[.type] as? FileAttributeType == .typeRegular else { throw Unreadable(message: "\(file) isn't a file") }
    if let size = attributes?[.size] as? Int, size > largest {
      throw Unreadable(message: "\(file) is \(size / 1_000_000) MB: too big to show")
    }
    let data = try Data(contentsOf: url)
    guard !data.prefix(8000).contains(0) else { throw Unreadable(message: "\(file) isn't text") }
    let overrides = await GuardedGit.overrides(in: root)
    async let tracked = GuardedGit.result(["ls-files", "-z", "--", file], in: root, overrides: overrides)
    async let diff = GuardedGit.result(["diff", rev] + GitDiff.flags + ["-U0", "--", file], in: root, overrides: overrides)
    let untracked = await tracked.stdout.isEmpty
    let text = String(decoding: data, as: UTF8.self)
    return Loaded(text: text, diff: untracked ? "" : await diff.stdout, untracked: untracked)
  }

  /// The file's URL, refused if it leads out of the worktree.
  private static func resolve(_ file: String, in root: String) throws -> URL {
    let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
    let url = URL(fileURLWithPath: root).appendingPathComponent(file).resolvingSymlinksInPath()
    guard !file.hasPrefix("/"), url.path.hasPrefix(base + "/") else {
      throw Unreadable(message: "\(file) isn't in this worktree")
    }
    return url
  }

  /// Every file git would show: tracked, and new ones it doesn't ignore.
  static func files(in root: String) async throws -> [String] {
    let output = try await GuardedGit.run(["ls-files", "--cached", "--others", "--exclude-standard", "-z"], in: root)
    var seen = Set<String>()
    return output.split(separator: "\0").map(String.init).filter { seen.insert($0).inserted }
  }

  /// The files changed since `rev`, new ones included.
  static func changes(in root: String, against rev: String) async throws -> [CodeChange] {
    let overrides = await GuardedGit.overrides(in: root)
    async let changed = GuardedGit.result(
      ["diff", "--name-status", "-z", "-M", "--ignore-submodules=dirty", rev], in: root, overrides: overrides)
    async let untracked = GuardedGit.result(
      ["ls-files", "--others", "--exclude-standard", "-z"], in: root, overrides: overrides)
    return await CodeChanges.parse(nameStatus: changed.stdout, untracked: untracked.stdout)
  }

  /// Where `name` is declared in the worktree, best first.
  static func definitions(of name: String, in root: String, from file: String?) async throws -> [CodeDefinitions.Hit] {
    guard CodeDefinitions.isName(name) else { return [] }
    let result = await GuardedGit.result(CodeDefinitions.grepArguments(name), in: root)
    // grep exits 1 when nothing matched.
    guard result.ok else { return [] }
    return CodeDefinitions.hits(result.stdout, name: name, from: file)
  }

  /// Of the changed `paths` (relative to the worktree at `root`), the ones
  /// to follow, in order: files that exist, outside any repository inside
  /// this one (a submodule, another worktree), that git doesn't ignore.
  static func followable(_ paths: [String], in root: String) async -> [String] {
    let fm = FileManager.default
    var nested: [String: Bool] = [:]
    func insideRepository(_ path: String) -> Bool {
      var folder = ""
      for part in path.split(separator: "/").dropLast() {
        folder += (folder.isEmpty ? "" : "/") + part
        if let known = nested[folder] {
          if known { return true } else { continue }
        }
        let found = fm.fileExists(atPath: root + "/" + folder + "/.git")
        nested[folder] = found
        if found { return true }
      }
      return false
    }
    let candidates = paths.filter { path in
      var directory: ObjCBool = false
      return !insideRepository(path) && fm.fileExists(atPath: root + "/" + path, isDirectory: &directory)
        && !directory.boolValue
    }
    guard !candidates.isEmpty else { return [] }
    // Tracked files are never ignored; check-ignore names the ignored rest.
    let input = Data(candidates.map { $0 + "\0" }.joined().utf8)
    let ignored = await GuardedGit.result(["check-ignore", "-z", "--stdin"], in: root, input: input)
    let skip = Set(ignored.stdout.split(separator: "\0").map(String.init))
    return candidates.filter { !skip.contains($0) }
  }

  /// What the changes are marked against: the last commit, or where the
  /// branch left the default branch (nil when there's none to compare with).
  static func revision(_ base: CodeView.Base, in root: String, repository: String) async -> String? {
    switch base {
    case .head: return "HEAD"
    case .branch:
      let branch = await Git.defaultBase(root: repository)
      guard branch != "HEAD" else { return nil }
      let result = await GuardedGit.result(["merge-base", "HEAD", branch], in: root)
      let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      return result.ok && !sha.isEmpty ? sha : nil
    }
  }
}
