import SwiftUI

/// An agent's state as one symbol: needs you pulses, working spins, done is a
/// check; idle shows nothing.
struct AgentGlyph: View {
  let state: AgentState?

  var body: some View {
    switch state {
    case .needsAction:
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(.orange)
        .symbolEffect(.pulse, isActive: !Snapshot.isActive)
        .help("Needs you")
    case .working:
      Image(systemName: "progress.indicator")
        .foregroundStyle(.primary)
        .symbolEffect(.variableColor.iterative, isActive: !Snapshot.isActive)
        .help("Working")
    case .done:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .help("Done")
    case .idle, nil:
      EmptyView()
    }
  }
}
