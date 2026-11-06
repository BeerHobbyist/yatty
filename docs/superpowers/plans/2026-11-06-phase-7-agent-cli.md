# Phase 7: Agent CLI and Fence — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Agents in Yatty's terminals drive their worktree's tabs with a `yatty` CLI — run a dev server in its own tab, read its output, send it keys, open a diff, notify the user — and inside fence they can do so without a way out of the sandbox. agentree's `agentree tab …` and its broker.

**Architecture:** A second SwiftPM executable, `yatty-cli` (installed in the bundle as `Contents/Resources/bin/yatty`, on the PATH of every Yatty terminal and in `$YATTY_CLI`), sends one JSON line per request over a Unix socket to the app and prints the answer. The app listens on two sockets in `~/.local/state/yatty/`: `app.sock` (everything; fence never allows it) and `sandbox.sock` (the only one a fenced agent may be allowed; requests there follow the sandbox rules whatever they claim). The CLI picks `sandbox.sock` when `$FENCE_SANDBOX` is set. Tab operations act on the requesting worktree (`$YATTY_WORKTREE`, or `--worktree`); reading and sending go through zmx (`history`, `send`).

**Spec:** roadmap Phase 7; agentree README "The agent CLI" and "Running agents in fence", DEVLOG "Agent CLI" and "Sandbox broker (fence)", `src/cli.ts`, `src/services/broker.ts`, `skills/agentree/SKILL.md`.

## Global Constraints

See the roadmap. Commands: `tab list [--json]`, `tab new [--name N] [--select] [-- COMMAND...]`, `tab read TAB [--lines N]`, `tab send TAB TEXT... [--key KEY]`, `tab select|rename|close TAB`, `diff [working|staged|base|REF]`, `notify MESSAGE...`, `status [--json]`, `skill install|uninstall|show`. `TAB` is a tab's name or 1-based index. `tab new` opens in the background (never steals the user's view) unless `--select`, refuses a name already in use, and types the command into a fresh shell so the tab outlives it; `tab close` refuses the last tab. Exit status 0 on success, 1 with a one-line message on stderr otherwise.

Sandbox rules (requests on `sandbox.sock`): what it starts runs in `sandboxCommand` (config.json; a command prefix read by `/bin/sh`), at the worktree; with no `sandboxCommand` nothing is started; it types only into panes it started that way (marked in the layout, `TerminalTab.sandboxed`); listing, reading, selecting, renaming and closing work on any tab.

## Review Focus

1. A fenced agent can't get an unsandboxed command run: every `sandbox.sock` path that starts a process wraps it in `sandboxCommand`, and `tab send` into an unmarked pane is refused — test on `CLIRequest.authorize(_:sandboxed:sandboxCommand:target:)`.
2. Two requests in one burst (`tab new dev` twice) never create two `dev` tabs — test on `WorktreeLayout.tabNamed`.
3. `tab read` of a tab whose pane died returns an error, not a hang — test on the zmx failure mapping.
4. Arguments with spaces, quotes or newlines survive CLI → JSON → app → zmx unchanged — round-trip test on `CLIRequest` encoding and `Zmx.sendArguments`.
5. The CLI with no app running prints "Yatty isn't running" and exits 1 within a second — test on the CLI's connect error mapping.

- [ ] Task 1: protocol + CLI — `Sources/YattyCLI/main.swift` (new target `yatty-cli`), `Sources/Yatty/CLI/CLIProtocol.swift` shared by both via a small `YattyProtocol` target (`CLIRequest`, `CLIResponse`, socket paths), argument parsing tested in `Tests/YattyTests/CLITests.swift`; `make app` bundles it.
- [ ] Task 2: app server — `Sources/Yatty/CLI/CLIServer.swift` (two `NWListener`s on Unix sockets), `Sources/Yatty/CLI/CLIHandler.swift` (ops → `AppStore` / zmx; sandbox rules); pane env `YATTY_CLI`, `YATTY_SOCKET`, PATH with the CLI's directory; tab names and indices; `tab new` in the background; snapshot-free (tested by running the CLI against a test server in `CLITests`).
- [ ] Task 3: agents learn about it — a SessionStart hook prints a short note (only where `$YATTY_CLI` is set); `skills/yatty/SKILL.md` (when to use the CLI, the dev-server workflow, etiquette); `yatty skill install|uninstall|show` (`$CLAUDE_CONFIG_DIR` or `~/.claude/skills/yatty/`); README section "Running agents in fence" with the exact `allowUnixSockets` entry for `sandbox.sock`.
- [ ] Task 4: verify (tests; a scripted end-to-end run of the CLI against the app's handler; fresh verifier; one re-verify), tick the roadmap, commit.
