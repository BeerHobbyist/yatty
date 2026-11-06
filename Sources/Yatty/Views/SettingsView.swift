import SwiftUI

/// Yatty's settings (⌘,): `config.json`, applied as they change.
struct SettingsView: View {
  @Environment(AppStore.self) private var store
  @State private var draft = YattyConfig()
  @State private var loaded = false

  var body: some View {
    Form {
      Section("Agents") {
        TextField("Agent command", text: $draft.agentCommand, prompt: Text("caffeinate -is claude"))
        Text("Typed into a new worktree's first terminal and into New Agent tabs. Leave it empty to start none.")
          .font(.caption).foregroundStyle(.secondary)
        Toggle("Notify me when an agent needs me or finishes", isOn: $draft.notifications)
      }
      Section("Repositories") {
        TextField("Clone into", text: $draft.cloneDirectory, prompt: Text("~/yatty"))
        Text("Where repositories added from GitHub are cloned.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Sandbox") {
        TextField(
          "Sandbox command",
          text: Binding(get: { draft.sandboxCommand ?? "" }, set: { draft.sandboxCommand = $0 }),
          prompt: Text("fence --"))
        Text("What a fenced agent's `yatty tab new` and `yatty diff` run in. Leave it empty and Yatty starts nothing for one.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let error = store.settingsError {
        Text(error).font(.caption).foregroundStyle(.red)
      }
    }
    .formStyle(.grouped)
    .frame(width: 520)
    .onAppear {
      draft = store.config
      loaded = true
    }
    .onChange(of: draft) {
      if loaded { store.applySettings(draft) }
    }
  }
}
