import AppKit
import Observation

/// Every worktree's pull request badge, and the details of the one the
/// inspector shows. GitHub is asked only while Yatty is the active app.
@MainActor
@Observable
final class PullRequestStore {
  /// Per worktree: nil = no pull request; missing = not known yet.
  private(set) var badges: [String: BranchPullRequest?] = [:]
  private(set) var details: [String: PullRequestDetails] = [:]
  private(set) var inlineComments: [String: [GitHub.InlineComment]] = [:]
  private(set) var detailsRefreshed: [String: Date] = [:]
  private(set) var detailsFailed: Set<String> = []
  private(set) var refreshingDetails: Set<String> = []

  @ObservationIgnored private weak var store: AppStore?
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var lastAsked: [String: Date] = [:]
  @ObservationIgnored private var asking: Set<String> = []

  func start(store: AppStore) {
    self.store = store
    timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshAll() }
    }
  }

  func badge(for worktree: Worktree) -> BranchPullRequest? { badges[worktree.id] ?? nil }

  /// `YATTY_BADGE_FIXTURE=<json file>`: badges by branch, standing in for gh
  /// (snapshots). `{"feature/x": {"number": 4, "checks": "pass", "isDraft": false, "merged": false}}`
  private static func badgeFixture() -> [String: BranchPullRequest]? {
    guard let path = ProcessInfo.processInfo.environment["YATTY_BADGE_FIXTURE"], !path.isEmpty,
      let data = FileManager.default.contents(atPath: path),
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }
    return json.compactMapValues { $0 as? [String: Any] }.mapValues { entry in
      BranchPullRequest(
        number: entry["number"] as? Int ?? 0, title: entry["title"] as? String ?? "",
        url: entry["url"] as? String ?? "", isDraft: entry["isDraft"] as? Bool ?? false,
        merged: entry["merged"] as? Bool ?? false,
        checks: (entry["checks"] as? String).flatMap(CheckState.init(rawValue:)), headOid: "")
    }
  }

  /// A failed refresh keeps the last good answer.
  nonisolated static func apply(result: Result<BranchPullRequest?, Error>, to old: BranchPullRequest??) -> BranchPullRequest?? {
    switch result {
    case .success(let badge): .some(badge)
    case .failure: old
    }
  }

  func refreshAll(force: Bool = false) {
    guard let store, NSApp.isActive || force || Snapshot.isActive else { return }
    for repo in store.repos where repo.nameWithOwner != nil {
      for worktree in store.worktrees[repo.id] ?? [] { refresh(worktree, in: repo, force: force) }
    }
  }

  /// At most once every 15 seconds per worktree unless forced, four at once.
  func refresh(_ worktree: Worktree, in repo: Repo, force: Bool = false) {
    guard let nameWithOwner = repo.nameWithOwner, let branch = worktree.branch, worktree.exists,
      !asking.contains(worktree.id), asking.count < 4
    else { return }
    if let fixture = Self.badgeFixture() {
      badges[worktree.id] = .some(fixture[branch])
      return
    }
    if !force, let last = lastAsked[worktree.id], Date().timeIntervalSince(last) < 15 { return }
    asking.insert(worktree.id)
    lastAsked[worktree.id] = Date()
    Task {
      defer { asking.remove(worktree.id) }
      let result: Result<BranchPullRequest?, Error>
      do {
        result = .success(
          try await GitHub.pullRequest(forBranch: branch, in: nameWithOwner, worktreePath: worktree.path))
      } catch {
        result = .failure(error)
      }
      let old = badges[worktree.id]
      if let updated = Self.apply(result: result, to: old), old != .some(updated) {
        badges[worktree.id] = updated
      }
    }
  }

  /// Re-reads the inspector's details for the worktree's pull request.
  func refreshDetails(for worktree: Worktree, in repo: Repo) {
    guard let nameWithOwner = repo.nameWithOwner, let badge = badge(for: worktree),
      !refreshingDetails.contains(worktree.id)
    else { return }
    refreshingDetails.insert(worktree.id)
    Task {
      defer { refreshingDetails.remove(worktree.id) }
      do {
        let (fresh, inline) = try await GitHub.pullRequestDetails(badge.number, in: nameWithOwner)
        details[worktree.id] = fresh
        inlineComments[worktree.id] = inline
        detailsRefreshed[worktree.id] = Date()
        detailsFailed.remove(worktree.id)
      } catch {
        detailsFailed.insert(worktree.id)
      }
    }
  }

  /// After a merge: everything about this repository is asked again.
  func invalidate(_ repo: Repo) {
    guard let store else { return }
    for worktree in store.worktrees[repo.id] ?? [] {
      lastAsked[worktree.id] = nil
      refresh(worktree, in: repo, force: true)
      refreshDetails(for: worktree, in: repo)
    }
  }
}
