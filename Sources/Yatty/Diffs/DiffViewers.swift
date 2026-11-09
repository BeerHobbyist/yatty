import Foundation

/// What to diff, as `git diff` arguments.
enum DiffTarget: Hashable, Codable, Sendable {
  case working
  case staged
  /// Against the base branch (`origin/main`): what the branch adds.
  case base(String)
  /// A ref or a commit.
  case ref(String)
  /// `A..B` from the commit picker.
  case range(String)

  var args: [String] {
    switch self {
    case .working: []
    case .staged: ["--staged"]
    case .base(let base): ["\(base)...HEAD"]
    case .ref(let ref): [ref]
    case .range(let range): [range]
    }
  }

  var title: String {
    switch self {
    case .working: "Working changes"
    case .staged: "Staged"
    case .base(let base): "vs \(base)"
    case .ref(let ref): ref
    case .range(let range): range
    }
  }
}

/// The diff viewers agentree offers, each turning `git diff` arguments into
/// a shell command (agentree's src/services/diff.ts).
enum DiffViewer: String, CaseIterable, Codable, Sendable {
  /// Yatty's own diff tab (`DiffTabView`); the rest run in a terminal tab.
  case yatty
  case hunk, diffnav, delta, difftastic, lumen, diffview, git

  var label: String {
    switch self {
    case .yatty: "Yatty"
    case .diffview: "nvim diffview"
    case .git: "git diff"
    default: rawValue
    }
  }

  /// Programs it needs on PATH.
  var needs: [String] {
    switch self {
    case .yatty: []
    case .hunk: ["hunk"]
    case .diffnav: ["diffnav", "delta"]
    case .delta: ["delta"]
    case .difftastic: ["difft"]
    case .lumen: ["lumen"]
    case .diffview: ["nvim"]
    case .git: ["git"]
    }
  }

  /// Picked by default when installed; diffview only when chosen (the
  /// plugin can't be detected).
  var auto: Bool { self != .diffview }

  /// The terminal command; Yatty's own viewer has none (`DiffTabView`).
  func command(args: [String]) -> String {
    switch self {
    case .yatty:
      return Self.git(args)
    case .hunk:
      return (["hunk", "diff"] + args).map(shellQuote).joined(separator: " ")
    case .diffnav:
      return Self.git(args, config: ["color.ui=never", "core.pager=cat"]) + " | diffnav"
    case .delta:
      return "DELTA_PAGER='less -R' " + Self.git(args, config: ["core.pager=delta --side-by-side --navigate --paging=always"])
    case .difftastic:
      return "DFT_COLOR=always DFT_WIDTH=$(tput cols 2>/dev/null || echo 120) "
        + Self.git(args, config: ["diff.external=difft", "core.pager=less -R"])
    case .lumen:
      // No flag for staged changes: those open in plain git.
      return args.contains("--staged")
        ? Self.git(args) : (["lumen", "diff"] + args).map(shellQuote).joined(separator: " ")
    case .diffview:
      let command = (["DiffviewOpen"] + args.map { $0 == "--staged" ? "--cached" : $0 }).joined(separator: " ")
      return ["nvim", "-c", command].map(shellQuote).joined(separator: " ")
    case .git:
      return Self.git(args)
    }
  }

  /// `git diff` paged by plain `less -R` with `LESS=R` (git's default `FRX`
  /// quits when the diff fits on a screen, which would close the tab), never
  /// the user's own core.pager.
  private static func git(_ args: [String], config: [String] = ["core.pager=less -R"]) -> String {
    "LESS=R " + (["git"] + config.flatMap { ["-c", $0] } + ["diff"] + args).map(shellQuote).joined(separator: " ")
  }
}

/// One commit of the branch, newest first in the picker.
struct Commit: Equatable, Identifiable, Sendable {
  var sha: String
  var short: String
  /// The first parent, or the empty tree for a root commit.
  var parent: String
  var subject: String
  var id: String { sha }
}

enum DiffViewers {
  /// The command a diff tab runs: an empty diff says so and waits for Enter
  /// instead of the viewer exiting at once (the tab would just flash).
  static func command(_ viewer: DiffViewer, args: [String]) -> String {
    let quiet = (["git", "diff", "--quiet"] + args).map(shellQuote).joined(separator: " ")
    return "if \(quiet); then printf '\\n  No changes to show.\\n\\n  Press Enter to close. '; read -r _; "
      + "else \(viewer.command(args: args)); fi"
  }

  /// The viewers whose programs are on `path` (colon-separated).
  static func available(in path: String) -> [DiffViewer] {
    let dirs = path.split(separator: ":").map(String.init)
    func installed(_ program: String) -> Bool {
      dirs.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(program)") }
    }
    return DiffViewer.allCases.filter { $0.needs.allSatisfy(installed) }
  }

  /// The chosen viewer if it's installed, else the first installed automatic one, else git.
  static func resolve(_ choice: DiffViewer?, available: [DiffViewer]) -> DiffViewer {
    if let choice, available.contains(choice) { return choice }
    return DiffViewer.allCases.first { $0.auto && $0 != .git && available.contains($0) } ?? .git
  }

  /// For a sandboxed agent: never Yatty's window, which runs git in the app,
  /// outside the sandbox; the user's terminal viewer, else the first installed.
  static func forSandbox(_ viewer: DiffViewer, available: [DiffViewer]) -> DiffViewer {
    viewer == .yatty ? resolve(nil, available: available.filter { $0 != .yatty }) : viewer
  }

  static func next(after current: DiffViewer, available: [DiffViewer]) -> DiffViewer {
    let list = available.isEmpty ? [.git] : available
    let index = list.firstIndex(of: current) ?? -1
    return list[(index + 1) % list.count]
  }

  /// The commits from the marked one to the one under the cursor, both
  /// included — or, with nothing marked, from the cursor's to HEAD.
  static func pickCommits(_ commits: [Commit], cursor: Int, mark: String?) -> (range: String, label: String)? {
    guard commits.indices.contains(cursor) else { return nil }
    func count(_ n: Int) -> String { "\(n) commit\(n == 1 ? "" : "s")" }
    let at = commits[cursor]
    guard let mark, let marked = commits.firstIndex(where: { $0.sha == mark }) else {
      return ("\(at.parent)..HEAD", "\(at.short) → HEAD · \(count(cursor + 1))")
    }
    let older = commits[max(marked, cursor)]
    let newer = commits[min(marked, cursor)]
    let n = abs(marked - cursor) + 1
    return (
      "\(older.parent)..\(newer.sha)",
      n == 1 ? "\(newer.short) · \(count(1))" : "\(older.short) → \(newer.short) · \(count(n))"
    )
  }
}

extension Git {
  /// `git log --first-parent --format=%H%x1f%h%x1f%P%x1f%s` lines; a root
  /// commit's parent is the empty tree.
  static func parseCommits(_ log: String, emptyTree: String) -> [Commit] {
    log.split(separator: "\n").compactMap { line in
      let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
      guard fields.count >= 4 else { return nil }
      let parent = fields[2].split(separator: " ").first.map(String.init) ?? emptyTree
      return Commit(sha: fields[0], short: fields[1], parent: parent, subject: fields[3])
    }
  }

  /// The branch's own commits (since `base`), else the last 50.
  static func branchCommits(path: String, base: String) async -> [Commit] {
    func log(_ args: [String]) async -> String {
      // Guarded: log.showSignature in the repository's config would run gpg.program.
      (try? await GuardedGit.run(["log", "--first-parent", "--format=%H%x1f%h%x1f%P%x1f%s"] + args, in: path)) ?? ""
    }
    var out = await log(["--max-count=200", "\(base)..HEAD"])
    if out.isEmpty { out = await log(["--max-count=50", "HEAD"]) }
    let emptyTree = ((try? await run(["hash-object", "-t", "tree", "/dev/null"], in: path)) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return parseCommits(out, emptyTree: emptyTree)
  }
}

extension Run {
  /// The PATH the user's login shell sets up (where hunk, delta, claude…
  /// live), asked once; Homebrew's directories when that fails.
  static let loginPath: String = {
    let result = runSync(Zmx.loginShell, ["-l", "-c", "env"])
    let line = result.stdout.split(separator: "\n").first { $0.hasPrefix("PATH=") }
    guard result.ok, let line else { return searchPath }
    return String(line.dropFirst("PATH=".count))
  }()
}
