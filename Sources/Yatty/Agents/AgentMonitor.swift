import AppKit
import Observation
import UserNotifications

/// Reads the agents' reports, corrects them by what their panes' screens do,
/// and tells the user when one needs them or finishes while they're elsewhere.
@MainActor
@Observable
final class AgentMonitor {
  /// Every reporting pane's state, as the sidebar shows it.
  private(set) var panes: [PaneKey: AgentState] = [:]

  @ObservationIgnored private weak var store: AppStore?
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var polling = false
  @ObservationIgnored private var tick = 0
  @ObservationIgnored private let launchedAt = Int(Date().timeIntervalSince1970)
  /// Per zmx session: a hash of its screen and when it last changed.
  @ObservationIgnored private var screens: [String: (hash: Int, changedAt: Int)] = [:]
  /// Per worktree: when the user last looked at it ("done" clears then).
  @ObservationIgnored private var viewed: [String: Int] = [:]
  @ObservationIgnored private var notificationsAllowed: Bool?

  func start(store: AppStore) {
    self.store = store
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        Task { await self.poll() }
      }
    }
  }

  /// A worktree's most urgent agent.
  func state(of worktree: Worktree) -> AgentState? {
    panes.filter { $0.key.worktree == worktree.id }.values.min()
  }

  func count(_ state: AgentState) -> Int {
    panes.values.filter { $0 == state }.count
  }

  /// The pane of `worktree` whose agent is in `state`, if any.
  func pane(of worktree: Worktree, in state: AgentState) -> PaneKey? {
    panes.first { $0.key.worktree == worktree.id && $0.value == state }?.key
  }

  // MARK: Polling

  private func poll() async {
    guard !polling, let store else { return }
    polling = true
    defer { polling = false }
    tick += 1
    let now = Int(Date().timeIntervalSince1970)
    if NSApp.isActive, let selection = store.selection { viewed[selection] = now }

    var paneOf: [String: PaneKey] = [:]
    for worktree in store.worktrees.values.joined() {
      for pane in store.layout(for: worktree).allPanes {
        paneOf[Zmx.sessionName(for: worktree.path, pane: pane)] = PaneKey(worktree: worktree.id, pane: pane)
      }
    }
    var reports: [String: AgentReport] = [:]
    let files = (try? FileManager.default.contentsOfDirectory(atPath: AgentHooks.directory.path)) ?? []
    for name in files where paneOf[name] != nil {
      let url = AgentHooks.directory.appendingPathComponent(name)
      if let content = try? String(contentsOf: url, encoding: .utf8), let report = AgentReport.parse(content) {
        reports[name] = report
      }
    }

    if !Snapshot.isActive {
      // A working or waiting agent's screen tells whether it still is.
      if tick % 2 == 0 {
        for (session, report) in reports where report.state == .working || report.state == .needsAction {
          await sample(session, now: now)
        }
      }
      // An agent that died fires no SessionEnd: its session is gone instead.
      if tick % 5 == 0, let live = await Zmx.sessions() {
        for session in reports.keys where !live.contains(session) {
          try? FileManager.default.removeItem(at: AgentHooks.directory.appendingPathComponent(session))
          reports[session] = nil
          screens[session] = nil
        }
      }
    }

    var states: [PaneKey: AgentState] = [:]
    for (session, report) in reports {
      guard let key = paneOf[session] else { continue }
      var state = AgentStatus.effective(report, lastScreenChange: screens[session]?.changedAt, now: now)
      if state == .done, let seen = viewed[key.worktree], seen >= report.since { state = .idle }
      states[key] = state
      let viewing = NSApp.isActive && store.selection == key.worktree
      if Self.shouldNotify(old: panes[key], new: state, since: report.since, launchedAt: launchedAt, viewing: viewing) {
        notify(key, state)
      }
    }
    if states != panes { panes = states }
  }

  private func sample(_ session: String, now: Int) async {
    let result = await Run.run(Zmx.executable, ["history", session, "--screen"], env: Zmx.environment)
    guard result.ok else { return }
    let hash = result.stdout.hashValue
    if screens[session]?.hash == hash { return }
    screens[session] = (hash, now)
  }

  /// Only news: into "needs you" or "done", newer than Yatty's launch, and
  /// not about the worktree the user is looking at.
  nonisolated static func shouldNotify(old: AgentState?, new: AgentState, since: Int, launchedAt: Int, viewing: Bool) -> Bool {
    (new == .needsAction || new == .done) && new != old && since >= launchedAt && !viewing
  }

  /// The next worktree after `after` in sidebar order (wrapping) whose agent
  /// needs the user, else is done.
  nonisolated static func nextTarget(order: [String], states: [String: AgentState], after: String?) -> String? {
    let start = after.flatMap { order.firstIndex(of: $0) } ?? -1
    let rotated = (1...max(order.count, 1)).compactMap { offset -> String? in
      order.isEmpty ? nil : order[(start + offset + order.count) % order.count]
    }
    return rotated.first { states[$0] == .needsAction } ?? rotated.first { states[$0] == .done }
  }

  // MARK: Notifications

  private func notify(_ key: PaneKey, _ state: AgentState) {
    guard let store, store.config.notifications, !Snapshot.isActive,
      let worktree = store.worktree(withID: key.worktree)
    else { return }
    let title = state == .needsAction ? "\(store.label(for: worktree)) needs you" : "\(store.label(for: worktree)) is done"
    let subtitle = store.repo(of: worktree)?.name ?? ""
    Task {
      let center = UNUserNotificationCenter.current()
      if notificationsAllowed == nil {
        notificationsAllowed = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
      }
      guard notificationsAllowed == true else { return }
      let content = UNMutableNotificationContent()
      content.title = title
      content.subtitle = subtitle
      content.sound = .default
      content.userInfo = ["worktree": key.worktree, "pane": key.pane]
      try? await center.add(
        UNNotificationRequest(identifier: "\(key.worktree)#\(key.pane)", content: content, trigger: nil))
    }
  }
}

/// Shows notifications while Yatty is in front too, and opens the pane a
/// clicked one is about.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
  @MainActor weak var store: AppStore?

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    let info = response.notification.request.content.userInfo
    guard let worktree = info["worktree"] as? String, let pane = info["pane"] as? String else { return }
    await MainActor.run {
      NSApp.activate()
      store?.reveal(PaneKey(worktree: worktree, pane: pane))
    }
  }
}
