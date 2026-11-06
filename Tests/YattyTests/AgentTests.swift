import Foundation
import Testing

@testable import Yatty

@Test func reportParses() {
  #expect(AgentReport.parse("working 1700000000\n") == AgentReport(state: .working, since: 1_700_000_000))
  #expect(AgentReport.parse("needs-action 5") == AgentReport(state: .needsAction, since: 5))
  #expect(AgentReport.parse("sleeping 5") == nil)
  #expect(AgentReport.parse("done") == nil)
  #expect(AgentReport.parse("") == nil)
}

@Test func stateOrdersByUrgency() {
  #expect(AgentState.needsAction < .working)
  #expect(AgentState.working < .done)
  #expect(AgentState.done < .idle)
}

@Test func interruptedWorkBecomesIdle() {
  let report = AgentReport(state: .working, since: 100)
  #expect(AgentStatus.effective(report, lastScreenChange: 100, now: 109) == .working)
  #expect(AgentStatus.effective(report, lastScreenChange: 100, now: 111) == .idle)
  // Still drawing its spinner: working.
  #expect(AgentStatus.effective(report, lastScreenChange: 110, now: 115) == .working)
  // Nothing known about the screen yet: trust the report.
  #expect(AgentStatus.effective(report, lastScreenChange: nil, now: 200) == .working)
}

@Test func answeredPromptBecomesWorking() {
  let report = AgentReport(state: .needsAction, since: 100)
  #expect(AgentStatus.effective(report, lastScreenChange: 101, now: 120) == .needsAction)
  #expect(AgentStatus.effective(report, lastScreenChange: 102, now: 120) == .working)
}

@Test func combinePicksMostUrgentThenNewest() {
  let reports = [
    AgentReport(state: .done, since: 50), AgentReport(state: .working, since: 10),
    AgentReport(state: .working, since: 30),
  ]
  #expect(AgentStatus.combine(reports) == AgentReport(state: .working, since: 30))
  #expect(AgentStatus.combine([]) == nil)
}

@Test func statusHooksAppendOnlyForClaude() {
  let path = "/h/claude-hooks.json"
  #expect(AgentHooks.withStatusHooks("caffeinate -is fence -- claude", settingsPath: path)
    == "caffeinate -is fence -- claude --settings '/h/claude-hooks.json'")
  #expect(AgentHooks.withStatusHooks("fence --settings x.json -- claude", settingsPath: path)
    == "fence --settings x.json -- claude --settings '/h/claude-hooks.json'")
  #expect(AgentHooks.withStatusHooks("claude --settings mine.json", settingsPath: path) == "claude --settings mine.json")
  #expect(AgentHooks.withStatusHooks("codex", settingsPath: path) == "codex")
}

@Test func hookCommandIsSilentAndGuarded() {
  let write = AgentHooks.command(for: .working)
  #expect(write.hasPrefix(#"[ -n "$YATTY_AGENT_DIR" ] && [ -n "$YATTY_PANE" ]"#))
  #expect(write.contains(">/dev/null 2>&1"))
  #expect(write.hasSuffix("exit 0"))
  #expect(write.contains("working"))
  #expect(AgentHooks.command(for: nil).contains("rm -f"))
}

@Test func hookCommandWritesAReport() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yatty-hook-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: dir) }
  let env = ["YATTY_AGENT_DIR": dir.path, "YATTY_PANE": "yatty-abc"]
  #expect(Run.runSync("/bin/sh", ["-c", AgentHooks.command(for: .needsAction)], env: env).ok)
  let written = try String(contentsOf: dir.appendingPathComponent("yatty-abc"), encoding: .utf8)
  #expect(AgentReport.parse(written)?.state == .needsAction)
  #expect(Run.runSync("/bin/sh", ["-c", AgentHooks.command(for: nil)], env: env).ok)
  #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("yatty-abc").path))
  // Outside a Yatty terminal it does nothing, and still succeeds.
  #expect(Run.runSync("/bin/sh", ["-c", AgentHooks.command(for: .done)], env: ["YATTY_AGENT_DIR": ""]).ok)
}

@Test func settingsListEveryEvent() throws {
  let hooks = try #require(AgentHooks.settings()["hooks"] as? [String: [[String: Any]]])
  #expect(Set(hooks.keys) == [
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd",
  ])
  let preToolUse = try #require(hooks["PreToolUse"])
  #expect(preToolUse.compactMap { $0["matcher"] as? String } == ["*", "AskUserQuestion|ExitPlanMode"])
}

private func hookCommands(_ settings: [String: Any]) -> [String] {
  let hooks = settings["hooks"] as? [String: [[String: Any]]] ?? [:]
  return hooks.values.flatMap { $0 }.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
    .compactMap { $0["command"] as? String }
}

@Test func mergeKeepsOtherHooksAndKeys() {
  let mine: [String: Any] = [
    "model": "opus",
    "hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]],
  ]
  let merged = ClaudeSettings.merging(mine, install: true)
  #expect(merged["model"] as? String == "opus")
  let commands = hookCommands(merged)
  #expect(commands.contains("say done"))
  #expect(commands.contains { $0.contains("YATTY_AGENT_DIR") })
}

@Test func mergeIsIdempotent() throws {
  let once = ClaudeSettings.merging([:], install: true)
  let twice = ClaudeSettings.merging(once, install: true)
  #expect(hookCommands(once).sorted() == hookCommands(twice).sorted())
  let data = try JSONSerialization.data(withJSONObject: twice, options: .sortedKeys)
  let again = try JSONSerialization.data(withJSONObject: ClaudeSettings.merging(twice, install: true), options: .sortedKeys)
  #expect(data == again)
}

@Test func removeLeavesNoTrace() {
  let mine: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]]]
  let removed = ClaudeSettings.merging(ClaudeSettings.merging(mine, install: true), install: false)
  #expect(hookCommands(removed) == ["say done"])
  #expect(ClaudeSettings.merging(ClaudeSettings.merging([:], install: true), install: false).isEmpty)
}

@Test func notifyOnlyForNewReportsOffScreen() {
  let launch = 1000
  #expect(AgentMonitor.shouldNotify(old: .working, new: .needsAction, since: 1001, launchedAt: launch, viewing: false))
  #expect(AgentMonitor.shouldNotify(old: .working, new: .done, since: 1001, launchedAt: launch, viewing: false))
  // Old news found at launch, the pane on screen, no change, or not worth a ping.
  #expect(!AgentMonitor.shouldNotify(old: nil, new: .done, since: 999, launchedAt: launch, viewing: false))
  #expect(!AgentMonitor.shouldNotify(old: .working, new: .needsAction, since: 1001, launchedAt: launch, viewing: true))
  #expect(!AgentMonitor.shouldNotify(old: .needsAction, new: .needsAction, since: 1001, launchedAt: launch, viewing: false))
  #expect(!AgentMonitor.shouldNotify(old: .idle, new: .working, since: 1001, launchedAt: launch, viewing: false))
}

@Test func jumpOrderWrapsAndPrefersNeedsAction() {
  let order = ["a", "b", "c", "d"]
  let states: [String: AgentState] = ["a": .needsAction, "b": .done, "d": .needsAction]
  #expect(AgentMonitor.nextTarget(order: order, states: states, after: "a") == "d")
  #expect(AgentMonitor.nextTarget(order: order, states: states, after: "d") == "a")
  #expect(AgentMonitor.nextTarget(order: order, states: ["b": .done, "c": .working], after: "c") == "b")
  #expect(AgentMonitor.nextTarget(order: order, states: ["c": .working], after: nil) == nil)
}
