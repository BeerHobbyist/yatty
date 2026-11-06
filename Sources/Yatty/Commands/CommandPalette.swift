import SwiftUI

/// Every action Yatty has, searchable, grouped by what it acts on, each with
/// the key that does it directly: nothing needs remembering, and using it
/// teaches the keys. ⏎ or a click picks one; the sheet closes, then it runs.
struct CommandPalette: View {
  let commands: [Command]
  /// The command picked, run once the palette is gone.
  let pick: (Command) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var highlighted: Command.ID?
  @FocusState private var fieldFocused: Bool

  var body: some View {
    let results = CommandMatch.filter(commands, query: query)
    VStack(spacing: 0) {
      TextField("Type a command or a worktree", text: $query)
        .textFieldStyle(.plain)
        .font(.title3)
        .padding(14)
        .focused($fieldFocused)
        .onKeyPress(.downArrow) {
          move(1, in: results)
          return .handled
        }
        .onKeyPress(.upArrow) {
          move(-1, in: results)
          return .handled
        }
        .onSubmit { if let command = current(in: results) { choose(command) } }
        .onChange(of: query) { highlighted = CommandMatch.filter(commands, query: query).first?.id }
      Divider()
      ScrollViewReader { proxy in
        List(selection: $highlighted) {
          if query.trimmingCharacters(in: .whitespaces).isEmpty {
            ForEach(groups(of: results), id: \.name) { group in
              Section(group.name) {
                ForEach(group.commands) { row($0) }
              }
            }
          } else {
            ForEach(results) { row($0) }
          }
        }
        .listStyle(.inset)
        .onChange(of: highlighted) { _, id in if let id { proxy.scrollTo(id) } }
      }
      .frame(height: 360)
      .overlay {
        if results.isEmpty { Text("No matching commands").foregroundStyle(.secondary) }
      }
    }
    .frame(width: 560)
    .onAppear {
      highlighted = results.first?.id
      fieldFocused = true
    }
  }

  private func row(_ command: Command) -> some View {
    HStack(spacing: 8) {
      Text(command.title).lineLimit(1)
      if let detail = command.detail {
        Text(detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 8)
      if let shortcut = command.shortcut {
        Text(shortcut.label).font(.callout.monospaced()).foregroundStyle(.secondary)
      }
    }
    .tag(command.id)
    .id(command.id)
    .contentShape(Rectangle())
    .onTapGesture { choose(command) }
  }

  private func groups(of commands: [Command]) -> [(name: String, commands: [Command])] {
    var groups: [(name: String, commands: [Command])] = []
    for command in commands {
      if let index = groups.firstIndex(where: { $0.name == command.group }) {
        groups[index].commands.append(command)
      } else {
        groups.append((command.group, [command]))
      }
    }
    return groups
  }

  private func current(in results: [Command]) -> Command? {
    results.first { $0.id == highlighted } ?? results.first
  }

  private func move(_ step: Int, in results: [Command]) {
    guard !results.isEmpty else { return }
    let index = results.firstIndex { $0.id == highlighted } ?? -step
    highlighted = results[min(max(index + step, 0), results.count - 1)].id
  }

  private func choose(_ command: Command) {
    pick(command)
    dismiss()
  }
}
