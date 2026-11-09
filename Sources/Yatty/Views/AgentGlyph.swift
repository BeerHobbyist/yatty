import AppKit
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

  /// `tint` for text: the same in dark mode, a darker shade in light mode,
  /// where system orange and green on white are too faint to read (~2:1).
  var textTint: Color {
    let light: NSColor =
      switch self {
      case .needsAction: NSColor(red: 0.60, green: 0.29, blue: 0.0, alpha: 1)
      case .working: NSColor(red: 0.0, green: 0.38, blue: 0.80, alpha: 1)
      case .done: NSColor(red: 0.11, green: 0.48, blue: 0.20, alpha: 1)
      case .idle: .secondaryLabelColor
      }
    let dark: NSColor =
      switch self {
      case .needsAction: .systemOrange
      case .working: .systemBlue
      case .done: .systemGreen
      case .idle: .secondaryLabelColor
      }
    return Color(
      nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      })
  }
}
