import Foundation
import Observation

/// Every repo `gh` can see, loaded a page at a time in the background and
/// kept for the app's lifetime: reopening the picker shows it at once.
@MainActor
@Observable
final class RepoCatalog {
  private(set) var repos: [RemoteRepo] = []
  private(set) var loading = false
  private(set) var error: String?
  @ObservationIgnored private var loaded = false

  /// Starts loading unless a load is running or already finished; a failed
  /// one is retried.
  func loadIfNeeded() {
    guard !loading, !loaded || error != nil else { return }
    Task { await load() }
  }

  private func load() async {
    loading = true
    error = nil
    defer { loading = false }
    if let fixture = Self.fixture() {
      repos = fixture
      loaded = true
      return
    }
    var collected: [RemoteRepo] = []
    var page = 1
    do {
      while true {
        let (batch, hasMore) = try await GitHub.repoPage(page)
        collected += batch
        // The first page shows at once; later ones extend it.
        repos = collected
        guard hasMore else { break }
        page += 1
      }
      loaded = true
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// `YATTY_REPO_FIXTURE=<json file>` stands in for `gh` (snapshots, tests).
  private static func fixture() -> [RemoteRepo]? {
    guard let path = ProcessInfo.processInfo.environment["YATTY_REPO_FIXTURE"], !path.isEmpty,
      let data = FileManager.default.contents(atPath: path)
    else { return nil }
    return try? JSONDecoder().decode([RemoteRepo].self, from: data)
  }
}
