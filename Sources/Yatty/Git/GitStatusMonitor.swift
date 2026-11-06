import Foundation
import Observation

/// Every worktree's git status, refreshed every 5 seconds and whenever an
/// agent's state changes (it has probably just edited something).
@MainActor
@Observable
final class GitStatusMonitor {
  private(set) var statuses: [String: GitStatus] = [:]

  @ObservationIgnored private weak var store: AppStore?
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var refreshing = false

  func start(store: AppStore) {
    self.store = store
    timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    refresh()
  }

  func status(of worktree: Worktree) -> GitStatus? { statuses[worktree.id] }

  /// Reads every existing worktree's status, at most four git runs at once.
  func refresh() {
    guard !refreshing, let store else { return }
    refreshing = true
    let worktrees = store.worktrees.values.joined().filter(\.exists)
    Task {
      defer { refreshing = false }
      var fresh: [String: GitStatus] = [:]
      for batch in stride(from: 0, to: worktrees.count, by: 4).map({ Array(worktrees[$0..<min($0 + 4, worktrees.count)]) }) {
        await withTaskGroup(of: (String, GitStatus?).self) { group in
          for worktree in batch {
            group.addTask { (worktree.id, await Git.status(path: worktree.path)) }
          }
          for await (id, status) in group {
            // A failed read keeps the last good status.
            if let status { fresh[id] = status } else if let old = statuses[id] { fresh[id] = old }
          }
        }
      }
      if fresh != statuses { statuses = fresh }
    }
  }
}
