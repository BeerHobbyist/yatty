import SwiftUI

/// An agent's state as one symbol: needs you pulses, working spins, done is a
/// check; idle shows nothing.
struct AgentGlyph: View {
  let state: AgentState?

  var body: some View {
    switch state {
    case .needsAction:
      Image(systemName: AgentState.needsAction.symbol)
        .foregroundStyle(AgentState.needsAction.tint)
        .symbolEffect(.pulse, isActive: !Snapshot.isActive)
        .help(AgentState.needsAction.title)
    case .working:
      Image(systemName: AgentState.working.symbol)
        .foregroundStyle(.primary)
        .symbolEffect(.variableColor.iterative, isActive: !Snapshot.isActive)
        .help(AgentState.working.title)
    case .done:
      Image(systemName: AgentState.done.symbol)
        .foregroundStyle(AgentState.done.tint)
        .help(AgentState.done.title)
    case .idle, nil:
      EmptyView()
    }
  }
}

extension AgentState {
  /// As the sidebar's section of it is called.
  var title: String {
    switch self {
    case .needsAction: "Needs you"
    case .working: "Working"
    case .done: "Done"
    case .idle: "Idle"
    }
  }

  var symbol: String {
    switch self {
    case .needsAction: "exclamationmark.circle.fill"
    case .working: "progress.indicator"
    case .done: "checkmark.circle.fill"
    case .idle: "circle"
    }
  }

  var tint: Color {
    switch self {
    case .needsAction: .orange
    case .working: .blue
    case .done: .green
    case .idle: .secondary
    }
  }
}
