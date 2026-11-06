import Foundation
import YattyProtocol

/// Claude Code hooks that report an agent's state to Yatty: each event
/// writes `<state> <epoch>` to `$YATTY_AGENT_DIR/$YATTY_PANE` (the pane's zmx
/// session name). Yatty's terminals set both; anywhere else they do nothing.
enum AgentHooks {
  /// In the state directory, not the config one: a sandboxed agent's hooks
  /// write here, and fence should keep it away from Yatty's config.
  static var directory: URL { CLIPaths.directory().appendingPathComponent("agents") }
  static var settingsURL: URL { ConfigFiles.directory.appendingPathComponent("claude-hooks.json") }

  /// nil state: the session ended, so its report goes.
  static let events: [(event: String, matcher: String?, state: AgentState?)] = [
    ("SessionStart", nil, .idle),
    ("UserPromptSubmit", nil, .working),
    // A question or a plan to approve waits on the user. No catch-all
    // PreToolUse "working" next to it: Claude runs an event's hooks at the
    // same time, so that one could land last and overwrite it.
    ("PreToolUse", "AskUserQuestion|ExitPlanMode", .needsAction),
    // Keeps "working" fresh, and ends a question once it's answered.
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
        // Each hook writes its own temp file ($$), then renames it into place.
        #"mkdir -p "$YATTY_AGENT_DIR""#
          + #" && printf '%s %s\n' \#(state.rawValue) "$(date +%s)" > \#(file).$$.tmp"#
          + " && mv -f \(file).$$.tmp \(file)"
      } else {
        "rm -f \(file)"
      }
    return #"[ -n "$YATTY_AGENT_DIR" ] && [ -n "$YATTY_PANE" ]"# + " && { \(action); } >/dev/null 2>&1; exit 0"
  }

  /// What an agent in a Yatty terminal is told when it starts.
  static let note = "You are running inside Yatty, a terminal workspace where each git worktree has tabs the user sees. "
    + "The `yatty` command (also at $YATTY_CLI) controls this worktree's tabs: run long-lived processes in their own tab "
    + "with `yatty tab new --name dev -- npm run dev` (opens in the background), read a tab's output with "
    + "`yatty tab read dev`, stop it with `yatty tab send dev --key C-c`, show the user a diff with `yatty diff`, "
    + "and ask for their attention with `yatty notify MESSAGE`. See `yatty --help`."

  /// The SessionStart hook that prints `note`: Claude adds what it prints to
  /// the conversation. Only where the CLI is; it names `YATTY_AGENT_DIR` so
  /// it's recognised as Yatty's (see ClaudeSettings).
  static var noteCommand: String {
    #"[ -n "$YATTY_AGENT_DIR" ] && [ -n "$YATTY_CLI" ] && printf '%s\n' "# + shellQuote(note) + "; exit 0"
  }

  /// The `--settings` file's content: one command hook per event, and the
  /// note at SessionStart.
  static func settings() -> [String: Any] {
    var hooks: [String: [[String: Any]]] = [:]
    for (event, matcher, state) in events {
      var commands: [[String: Any]] = [["type": "command", "command": command(for: state), "timeout": 5]]
      if event == "SessionStart" { commands.append(["type": "command", "command": noteCommand, "timeout": 5]) }
      var entry: [String: Any] = ["hooks": commands]
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
