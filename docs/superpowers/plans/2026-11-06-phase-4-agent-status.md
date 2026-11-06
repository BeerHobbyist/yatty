# Phase 4: Agent Status and Notifications — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The sidebar shows what every agent is doing (needs you, working, done, idle), Yatty tells you when one needs you or finishes while you're elsewhere, and one key takes you to it — agentree's agent status, natively.

**Architecture:** Claude Code hooks (a `--settings` file Yatty writes; optionally merged into the user's own Claude settings) write `<state> <epoch>` to `~/.config/yatty/agents/<zmx session name>`. An `AgentMonitor` polls that directory, maps each session to its pane, corrects stale reports against what the pane's screen does (`zmx history --screen`), and publishes a status per pane and per worktree. Notifications go through `UNUserNotificationCenter`.

**Tech Stack:** as in the roadmap; UserNotifications.

**Spec:** roadmap Phase 4; agentree `docs/DEVLOG.md` "Agent status" and `src/services/agents.ts` (hook events, `hookCommand`, `withStatusHooks`, `effectiveState`, `combineReports`, `withGlobalHooks`).

## Global Constraints

See the roadmap. Hooks print nothing (Claude feeds SessionStart/UserPromptSubmit stdout into the conversation) and do nothing outside a Yatty terminal. Report files are written atomically (`.tmp` + `mv`). The state words stay agentree's: `needs-action`, `working`, `done`, `idle`. Fenced agents may write `~/.config/yatty/agents/` (fence allows `~/.config/**`) and never reach zmx.

## Review Focus

1. An agent interrupted with Esc (no hook fires) stops showing "working" within ~10s once its screen stops changing — test on `AgentStatus.effective(_:lastScreenChange:now:)`.
2. A permission prompt answered by the user flips back to "working" as soon as the screen changes, not when the tool finishes — same test.
3. "Track every claude" merged into a settings file that has other hooks, keys and comments-free JSON leaves all of them intact, is idempotent, and is fully removable — test on `ClaudeSettings.merging(_:install:)`.
4. A report older than the app's launch never notifies — test on `AgentMonitor.shouldNotify(old:new:launchedAt:viewing:)`.
5. A `fence --settings x -- claude` command still gets Yatty's `--settings`, but a `claude --settings mine.json` command is left alone — test on `AgentHooks.withStatusHooks(_:settingsPath:)`.

---

### Task 1: Hooks and reports (pure logic)

**Files:** Create `Sources/Yatty/Agents/AgentHooks.swift`, `Sources/Yatty/Agents/AgentStatus.swift`, `Tests/YattyTests/AgentTests.swift`.

**Interfaces (Produces):**
- `enum AgentState: String, Codable, Comparable, Sendable { case needsAction = "needs-action", working, done, idle }` — `<` orders by urgency (needsAction most urgent).
- `struct AgentReport: Equatable, Sendable { var state: AgentState; var since: Int }`; `static func parse(_ content: String) -> AgentReport?` (`"<state> <epoch>"`, anything else nil).
- `enum AgentStatus`:
  - `static let workingSilence = 10` (seconds)
  - `static func effective(_ report: AgentReport, lastScreenChange: Int?, now: Int) -> AgentState` — working with no screen change for ≥ 10s (and reported ≥ 10s ago) → idle; needs-action whose screen changed after `since + 1` → working; else the report.
  - `static func combine(_ reports: [AgentReport]) -> AgentReport?` — most urgent; ties → newest.
- `enum AgentHooks`:
  - `static var directory: URL` (`~/.config/yatty/agents`, XDG-aware via `ConfigFiles.directory`), `static var settingsURL: URL` (`~/.config/yatty/claude-hooks.json`)
  - `static let events: [(event: String, matcher: String?, state: AgentState?)]` — `SessionStart` idle; `UserPromptSubmit` working; `PreToolUse "*"` working; `PreToolUse "AskUserQuestion|ExitPlanMode"` needs-action (after the `*` entry, so it wins); `PostToolUse "*"` working; `Notification "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input"` needs-action; `Stop` done; `SessionEnd` nil (= delete the report).
  - `static func command(for state: AgentState?) -> String` — `[ -n "$YATTY_AGENT_DIR" ] && [ -n "$YATTY_PANE" ] && { …; } >/dev/null 2>&1; exit 0`; writes via `.tmp` + `mv -f`; nil → `rm -f`.
  - `static func settings() -> [String: Any]` (`{"hooks": {event: [{matcher?, hooks: [{type: "command", command, timeout: 5}]}]}}`) and `static func install()` (write `settingsURL` when its content differs).
  - `static func withStatusHooks(_ command: String, settingsPath: String) -> String` — agentree's rule: if a word is exactly `claude` and no `--settings` follows it, append `--settings '<path>'`.
- Pane environment: `YATTY_AGENT_DIR` and `YATTY_PANE=<zmx session name>` added in `startTerminal`; the agent command typed into a new session goes through `withStatusHooks`.

- [ ] Tests: `reportParses`, `stateOrdersByUrgency`, `interruptedWorkBecomesIdle`, `answeredPromptBecomesWorking`, `combinePicksMostUrgentThenNewest`, `statusHooksAppendOnlyForClaude` (`caffeinate -is fence -- claude` gets it; `fence --settings x -- claude` gets it; `claude --settings mine.json` doesn't; `codex` doesn't), `hookCommandIsSilentAndGuarded`, `settingsListEveryEvent`.

### Task 2: Track every claude (global hooks)

**Files:** Create `Sources/Yatty/Agents/ClaudeSettings.swift`; tests in `AgentTests.swift`.

**Interfaces:**
- `enum ClaudeSettings { static var url: URL }` — `$CLAUDE_CONFIG_DIR/settings.json`, else `~/.claude/settings.json`.
- `static func merging(_ settings: [String: Any], install: Bool) -> [String: Any]` — removes every hook entry whose command mentions `YATTY_AGENT_DIR`, then (install) adds `AgentHooks.settings()`'s entries; other keys and hooks untouched; an emptied `hooks` key is dropped.
- `static func isInstalled() -> Bool`, `static func setInstalled(_ on: Bool) throws` — a file that isn't valid JSON is left alone (throws `GitError("… isn't valid JSON")`).
- Menu: Agents ▸ "Track Every Claude…" (checkmark when on); turning it on asks first (what it does, that it's reversible).

- [ ] Tests: `mergeKeepsOtherHooksAndKeys`, `mergeIsIdempotent`, `removeLeavesNoTrace`.

### Task 3: Monitor, sidebar, jump, notifications

**Files:** Create `Sources/Yatty/Agents/AgentMonitor.swift`, `Sources/Yatty/Views/AgentGlyph.swift`; modify `AppStore.swift` (owns the monitor; `jumpToNextAgent()`), `ContentView.swift` (row glyph, footer counts), `YattyApp.swift` (Agents menu), `AppStore+Terminals.swift` (pane env).

**Interfaces:**
- `@MainActor @Observable final class AgentMonitor`:
  - `private(set) var panes: [PaneKey: AgentState]`, `func state(of worktree: Worktree) -> AgentState?` (combined), `var counts: [AgentState: Int]`
  - polls every 1s: reads `AgentHooks.directory`, maps file name → `PaneKey` through the store's worktrees and layouts (`Zmx.sessionName(for:pane:)`); every 2s, for panes reported working or needs-action, hashes `zmx history <session> --screen` to track `lastScreenChange`; deletes reports of sessions `zmx list` no longer has (skipped when `zmx list` fails, and in snapshot mode).
  - "done" is shown until the user views that worktree (selected while the app is active) after the report's `since`; then it reads as idle.
  - `static func shouldNotify(old: AgentState?, new: AgentState, since: Int, launchedAt: Int, viewing: Bool) -> Bool` — only into needs-action or done, only for reports newer than launch, never for the pane on screen in the active app.
- Notifications: authorization asked the first time one would be posted; title "<label> needs you" / "<label> is done", subtitle the repository; clicking selects the worktree, its tab, focuses the pane and activates the app. `config.json` `notifications: false` turns them off.
- `AppStore.jumpToNextAgent()` — the next worktree in sidebar order after the selected one whose agent needs you, else is done; selects it and focuses that pane. Menu Agents ▸ "Go to Next Agent" ⌘⇧J; footer counts click to it too.
- `AgentGlyph(state:)` — needs-action: `exclamationmark.circle.fill`, orange, pulsing (`.symbolEffect(.pulse)`); working: `circle.dotted`, accent, rotating; done: `checkmark.circle.fill`, green; idle: nothing. Sidebar row: glyph before the label; a folded repository shows its most urgent glyph.

- [ ] Tests: `notifyOnlyForNewReportsOffScreen`, `jumpOrderWrapsAndPrefersNeedsAction` (on a pure `AgentMonitor.nextTarget(order:states:after:)`).
- [ ] Snapshot scene `agents`: sample reports (needs-action, working, done) under the sandbox's agents directory → sidebar glyphs and footer counts.

### Task 4: Verify and commit

- [ ] `make test`, `make app`, snapshots; fresh `verifier` on this plan + roadmap Phase 4 + Review Focus; fix; one re-verify round; tick the roadmap; progress-log row; commit.
