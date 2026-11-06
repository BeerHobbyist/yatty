import Foundation

/// What an agent is doing, most urgent first. The words are agentree's.
enum AgentState: String, Codable, Comparable, Sendable, CaseIterable {
  case needsAction = "needs-action"
  case working
  case done
  case idle

  private var urgency: Int {
    switch self {
    case .needsAction: 0
    case .working: 1
    case .done: 2
    case .idle: 3
    }
  }

  static func < (lhs: AgentState, rhs: AgentState) -> Bool { lhs.urgency < rhs.urgency }
}

/// One line a hook wrote: `<state> <epoch seconds>`.
struct AgentReport: Equatable, Sendable {
  var state: AgentState
  var since: Int

  static func parse(_ content: String) -> AgentReport? {
    let words = content.split(whereSeparator: \.isWhitespace)
    guard words.count == 2, let state = AgentState(rawValue: String(words[0])), let since = Int(words[1])
    else { return nil }
    return AgentReport(state: state, since: since)
  }
}

enum AgentStatus {
  /// A working agent whose screen hasn't changed for this long was stopped
  /// (Esc fires no hook): Claude's spinner keeps a working screen moving.
  static let workingSilence = 10
  /// How long after a "needs you" report its prompt may still be drawing.
  static let promptSettle = 2

  /// The report, corrected by what its pane's screen did. `lastScreenChange`:
  /// when the screen was last seen to change, nil when nobody has looked yet.
  /// `movedSinceReport`: the screen differs from how it looked the first
  /// time it was sampled after this report (the prompt as asked).
  static func effective(
    _ report: AgentReport, lastScreenChange: Int?, movedSinceReport: Bool, now: Int
  ) -> AgentState {
    func workingOrStopped() -> AgentState {
      guard let lastScreenChange, now - lastScreenChange >= workingSilence,
        now - report.since >= workingSilence
      else { return .working }
      return .idle
    }
    switch report.state {
    case .working:
      return workingOrStopped()
    // The prompt was answered: the agent is drawing again — and like any
    // working agent, one whose screen then stops was stopped.
    case .needsAction:
      return movedSinceReport ? workingOrStopped() : .needsAction
    default:
      return report.state
    }
  }

  /// What a worktree running several agents shows: the most urgent, then the newest.
  static func combine(_ reports: [AgentReport]) -> AgentReport? {
    reports.min { a, b in a.state != b.state ? a.state < b.state : a.since > b.since }
  }
}
