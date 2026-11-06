import Foundation

/// Claude Code hooks that report an agent's state to Yatty: each event
/// writes `<state> <epoch>` to `$YATTY_AGENT_DIR/$YATTY_PANE` (the pane's zmx
/// session name). Yatty's terminals set both; anywhere else they do nothing.
enum AgentHooks {
  static var directory: URL { ConfigFiles.directory.appendingPathComponent("agents") }
  static var settingsURL: URL { ConfigFiles.directory.appendingPathComponent("claude-hooks.json") }

  /// nil state: the session ended, so its report goes.
  static let events: [(event: String, matcher: String?, state: AgentState?)] = [
    ("SessionStart", nil, .idle),
    ("UserPromptSubmit", nil, .working),
    // Tool events keep "working" fresh; a question or a plan to approve waits
    // on the user (listed after "*", so it's the last word).
    ("PreToolUse", "*", .working),
    ("PreToolUse", "AskUserQuestion|ExitPlanMode", .needsAction),
    ("PostToolUse", "*", .working),
    ("Notification", "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input", .needsAction),
    ("Stop", nil, .done),
    ("SessionEnd", nil, nil),
  ]

  /// A hook's shell command. It prints nothing: Claude feeds the output of
  /// some hooks (SessionStart, UserPromptSubmit) into the conversation.
  static func command(for state: AgentState?) -> String {
    let file = #""$YATTY_AGENT_DIR/$YATTY_PANE""#
    let action =
      if let state {
        #"mkdir -p "$YATTY_AGENT_DIR""#
          + #" && printf '%s %s\n' \#(state.rawValue) "$(date +%s)" > \#(file).tmp"#
          + " && mv -f \(file).tmp \(file)"
      } else {
        "rm -f \(file)"
      }
    return #"[ -n "$YATTY_AGENT_DIR" ] && [ -n "$YATTY_PANE" ]"# + " && { \(action); } >/dev/null 2>&1; exit 0"
  }

  /// The `--settings` file's content: one command hook per event.
  static func settings() -> [String: Any] {
    var hooks: [String: [[String: Any]]] = [:]
    for (event, matcher, state) in events {
      var entry: [String: Any] = ["hooks": [["type": "command", "command": command(for: state), "timeout": 5]]]
      if let matcher { entry["matcher"] = matcher }
      hooks[event, default: []].append(entry)
    }
    return ["hooks": hooks]
  }

  /// Writes the settings file when it's missing or out of date.
  static func install() {
    guard let data = try? JSONSerialization.data(
      withJSONObject: settings(), options: [.prettyPrinted, .sortedKeys])
    else { return }
    if (try? Data(contentsOf: settingsURL)) == data { return }
    try? FileManager.default.createDirectory(at: ConfigFiles.directory, withIntermediateDirectories: true)
    try? data.write(to: settingsURL, options: .atomic)
  }

  /// `command` with the hooks attached when it starts `claude` and doesn't
  /// give it its own `--settings` (a wrapper's before it, like
  /// `fence --settings …`, doesn't count). Anything else runs untouched.
  static func withStatusHooks(_ command: String, settingsPath: String) -> String {
    let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
    guard let claude = words.firstIndex(of: "claude"), !words[(claude + 1)...].contains("--settings")
    else { return command }
    return command + " --settings " + shellQuote(settingsPath)
  }
}
