import Foundation

/// A repository `gh` can see.
struct RemoteRepo: Identifiable, Hashable, Sendable, Decodable {
  let name: String
  let nameWithOwner: String
  let description: String?
  let isPrivate: Bool

  var id: String { nameWithOwner }

  enum CodingKeys: String, CodingKey {
    case name
    case nameWithOwner = "full_name"
    case description
    case isPrivate = "private"
  }

  /// Matches first: exact name, name prefix, name contains, owner/name
  /// contains. Ties keep their order (most recently pushed first).
  static func ranked(_ repos: [RemoteRepo], query: String) -> [RemoteRepo] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return repos }
    func score(_ repo: RemoteRepo) -> Int {
      let name = repo.name.lowercased()
      if name == q { return 100 }
      if name.hasPrefix(q) { return 80 }
      if name.contains(q) { return 60 }
      if repo.nameWithOwner.lowercased().contains(q) { return 40 }
      return 0
    }
    return repos.enumerated()
      .map { (offset: $0.offset, repo: $0.element, score: score($0.element)) }
      .filter { $0.score > 0 }
      .sorted { ($0.score, -$0.offset) > ($1.score, -$1.offset) }
      .map(\.repo)
  }
}

struct OpenPullRequest: Identifiable, Hashable, Sendable, Decodable {
  let number: Int
  let title: String
  let headRefName: String
  /// From a fork.
  let isCrossRepository: Bool
  let author: Author

  struct Author: Hashable, Sendable, Decodable {
    let login: String
  }

  var id: Int { number }
}

/// The `gh` CLI, as the user is logged in to it.
enum GitHub {
  static let pageSize = 100

  /// One page of every repo the user can reach: owned, collaborator and
  /// organization repos, most recently pushed first.
  static func repoPage(_ page: Int) async throws -> (repos: [RemoteRepo], hasMore: Bool) {
    let query = "user/repos?per_page=\(pageSize)&page=\(page)&sort=pushed"
      + "&affiliation=owner,collaborator,organization_member"
    let repos = try JSONDecoder().decode([RemoteRepo].self, from: try await run(["api", query]))
    return (repos, repos.count == pageSize)
  }

  static func openPullRequests(_ nameWithOwner: String) async throws -> [OpenPullRequest] {
    // `YATTY_PR_FIXTURE=<json file>` stands in for gh (snapshots, tests).
    if let path = ProcessInfo.processInfo.environment["YATTY_PR_FIXTURE"], !path.isEmpty,
      let data = FileManager.default.contents(atPath: path)
    {
      return try JSONDecoder().decode([OpenPullRequest].self, from: data)
    }
    let out = try await run([
      "pr", "list", "-R", nameWithOwner, "--state", "open", "--limit", "100",
      "--json", "number,title,headRefName,isCrossRepository,author",
    ])
    return try JSONDecoder().decode([OpenPullRequest].self, from: out)
  }

  static func clone(_ nameWithOwner: String, to path: String) async throws {
    _ = try await run(["repo", "clone", nameWithOwner, path])
  }

  /// What went wrong, in words the user can act on.
  static func errorMessage(for result: ProcessResult) -> String {
    let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.status == 127 || stderr.contains("No such file") {
      return "gh isn't installed (brew install gh)."
    }
    if stderr.contains("auth login") {
      return "gh isn't logged in: run `gh auth login`."
    }
    return stderr.isEmpty ? "gh failed (exit \(result.status))." : stderr
  }

  private static func run(_ args: [String]) async throws -> Data {
    let result = await Run.run("/usr/bin/env", ["gh"] + args)
    guard result.ok else { throw GitError(message: errorMessage(for: result)) }
    return Data(result.stdout.utf8)
  }
}
