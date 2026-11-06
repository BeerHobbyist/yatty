import SwiftUI

/// Every key (⌘?): Yatty's commands that have one, by group, from the same
/// list the palette shows, and the terminal's own keys, which Ghostty gives
/// every pane (rebinding them in Ghostty's config works here too).
struct HelpView: View {
  let commands: [Command]

  /// Ghostty's defaults that aren't menu items.
  static let terminalKeys: [(keys: String, what: String)] = [
    ("⌘C / ⌘V", "copy / paste"),
    ("⌘A", "select all"),
    ("⌘K", "clear the screen"),
    ("⌘1 – ⌘9", "go to tab"),
    ("⌥⌘← ↑ ↓ →", "go to the pane that way"),
    ("⌘+ / ⌘- / ⌘0", "font size"),
    ("⌘↑ / ⌘↓", "previous / next prompt"),
    ("⇧⌘J", "go to the next agent that needs you"),
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text("Every action is also in the command palette (⇧⌘P): type a few letters of its name.")
          .foregroundStyle(.secondary)
        ForEach(groups, id: \.name) { group in
          VStack(alignment: .leading, spacing: 6) {
            Text(group.name).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
              ForEach(group.rows, id: \.what) { row in
                GridRow {
                  Text(row.keys).font(.body.monospaced()).foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                  Text(row.what)
                }
              }
            }
          }
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 460, minHeight: 420)
  }

  private var groups: [(name: String, rows: [(keys: String, what: String)])] {
    var groups: [(name: String, rows: [(keys: String, what: String)])] = []
    for command in commands {
      guard let shortcut = command.shortcut else { continue }
      let row = (keys: shortcut.label, what: command.title)
      if let index = groups.firstIndex(where: { $0.name == command.group }) {
        if !groups[index].rows.contains(where: { $0.what == row.what }) { groups[index].rows.append(row) }
      } else {
        groups.append((command.group, [row]))
      }
    }
    groups.append(("Terminal keys", Self.terminalKeys))
    return groups
  }
}
