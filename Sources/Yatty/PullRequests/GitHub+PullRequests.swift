import Foundation

extension GitHub {
  /// A pull request as `gh pr list --head` lists it.
  private struct ListedPullRequest: Decodable {
    struct Oid: Decodable { var oid: String }
    var number: Int
    var title: String
    var url: String
    var isDraft: Bool
    var state: String
    var headRefOid: String?
    var statusCheckRollup: [RawCheck]?
    var mergeCommit: Oid?
    var commits: [Oid]?
    var reviewDecision: String?

    func badge(merged: Bool) -> BranchPullRequest {
      BranchPullRequest(
        number: number, title: title, url: url, isDraft: isDraft, merged: merged,
        checks: PullRequests.summarize((statusCheckRollup ?? []).map(PullRequests.checkState)),
        headOid: headRefOid ?? "", reviewDecision: reviewDecision.flatMap { $0.isEmpty ? nil : $0 })
    }
  }

  /// The branch's open pull request, else a merged one that was this
  /// branch's (see `PullRequests.isThisBranchs`). Throws when gh fails, so a
  /// caller can keep the last good answer.
  static func pullRequest(
    forBranch branch: String, in nameWithOwner: String, worktreePath: String
  ) async throws -> BranchPullRequest? {
    let data = try await run([
      "pr", "list", "-R", nameWithOwner, "--head", branch, "--state", "all", "--limit", "5", "--json",
      "number,title,url,isDraft,statusCheckRollup,state,headRefOid,mergeCommit,commits,reviewDecision",
    ])
    let prs = try JSONDecoder().decode([ListedPullRequest].self, from: data)
    if let open = prs.first(where: { $0.state == "OPEN" }) { return open.badge(merged: false) }
    guard let head = try? await Git.run(["rev-parse", "HEAD"], in: worktreePath)
      .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty
    else { return nil }
    for pr in prs where pr.state == "MERGED" {
      let commits = (pr.commits ?? []).map(\.oid)
      let cheap = pr.headRefOid == head || commits.contains(head)
      var past = false
      if !cheap, let prHead = pr.headRefOid {
        past = await Git.isAncestor(prHead, of: head, in: worktreePath)
      }
      guard cheap || past else { continue }
      let mergeIn = await pr.mergeCommit.asyncMap { await Git.isAncestor($0.oid, of: head, in: worktreePath) } ?? false
      if PullRequests.isThisBranchs(
        head: head, prHead: pr.headRefOid, prCommits: commits, prHeadIsAncestorOfHead: past,
        mergeCommitIsAncestorOfHead: mergeIn)
      {
        return pr.badge(merged: true)
      }
    }
    return nil
  }

  /// The inspector's data; review threads are best effort.
  static func pullRequestDetails(_ number: Int, in nameWithOwner: String) async throws
    -> (details: PullRequestDetails, threads: [ReviewThread])
  {
    let environment = ProcessInfo.processInfo.environment
    if let path = environment["YATTY_PR_DETAILS_FIXTURE"], !path.isEmpty,
      let data = FileManager.default.contents(atPath: path)
    {
      let threads = environment["YATTY_PR_THREADS_FIXTURE"].flatMap { FileManager.default.contents(atPath: $0) }
        .flatMap(ReviewThread.parse) ?? []
      return (try JSONDecoder().decode(PullRequestDetails.self, from: data), threads)
    }
    let data = try await run(["pr", "view", String(number), "-R", nameWithOwner, "--json", PullRequestDetails.fields])
    let details = try JSONDecoder().decode(PullRequestDetails.self, from: data)
    let parts = nameWithOwner.split(separator: "/", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return (details, []) }
    let threads = (try? await run([
      "api", "graphql", "-f", "query=\(ReviewThread.query)", "-f", "owner=\(parts[0])", "-f", "name=\(parts[1])",
      "-F", "number=\(number)",
    ])).flatMap(ReviewThread.parse) ?? []
    return (details, threads)
  }

  static func mergeSettings(_ nameWithOwner: String) async throws -> MergeSettings {
    // Snapshots can't reach GitHub: every method, auto-merge on.
    if Snapshot.isActive { return MergeSettings(methods: MergeMethod.allCases, autoMerge: true) }
    let data = try await run(["api", "repos/\(nameWithOwner)"])
    let json = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    return MergeSettings.decode(json)
  }

  /// Pinned to `headSha`, so a push not yet seen here isn't merged with it.
  /// Never `--delete-branch`: the worktree still has the branch checked out.
  static func merge(number: Int, in nameWithOwner: String, method: MergeMethod, auto: Bool, headSha: String) async throws {
    var args = ["pr", "merge", String(number), "-R", nameWithOwner, "--\(method.rawValue)"]
    if auto { args.append("--auto") }
    if !headSha.isEmpty { args += ["--match-head-commit", headSha] }
    _ = try await run(args)
  }
}

extension Optional {
  fileprivate func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
    guard let value = self else { return nil }
    return await transform(value)
  }
}
