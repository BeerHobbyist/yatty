# Phase 7: Agent CLI and Fence — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Agents in Yatty's terminals drive their worktree's tabs with a `yatty` CLI — run a dev server in its own tab, read its output, send it keys, open a diff, notify the user — and inside fence they can do so without a way out of the sandbox. agentree's `agentree tab …` and its broker.

**Architecture:** A second SwiftPM executable, `yatty-cli` (installed in the bundle as `Contents/Resources/bin/yatty`, on the PATH of every Yatty terminal and in `$YATTY_CLI`), sends one JSON line per request over a Unix socket to the app and prints the answer. The app listens on two sockets in `~/.local/state/yatty/`: `app.sock` (everything; fence never allows it) and `sandbox.sock` (the only one a fenced agent may be allowed; requests there follow the sandbox rules whatever they claim). The CLI picks `sandbox.sock` when `$FENCE_SANDBOX` is set. Tab operations act on the requesting worktree (`$YATTY_WORKTREE`, or `--worktree`); reading and sending go through zmx (`history`, `send`).

**Spec:** roadmap Phase 7; agentree README "The agent CLI" and "Running agents in fence", DEVLOG "Agent CLI" and "Sandbox broker (fence)", `src/cli.ts`, `src/services/broker.ts`, `skills/agentree/SKILL.md`.

## Status

- Done (`a59a99e`…`ad964b4` and the busy-answer fix after it). Verified: 90 tests; `scripts/zmx-e2e.sh`; `scripts/cli-e2e.sh` against a real, isolated Yatty (background tabs, send and keys, rename/select/close, sandbox rules with a stand-in sandbox, sandboxed diff, status, no-app); a fresh verifier found 6 defects (a negative `lines` crashed the app, non-reading clients wedged the server, fish quoting, connection floods, tab numbers, tab names), all fixed and re-verified.
- Changes from the plan: no `YATTY_SOCKET` (panes get `YATTY_STATE_DIR`; the CLI derives both sockets from it); agent reports moved to `~/.local/state/yatty/agents` so fence can deny writes to `~/.config/yatty/**` (a sandbox that edits `sandboxCommand` would escape it); a per-socket cap of 8 connections.
- Known, by design: a sandboxed agent may act on another worktree's tabs (`--worktree`, as agentree), and one that holds 8 connections open keeps `sandbox.sock` busy for other fenced agents (never `app.sock`).
- Not exercised end to end: `yatty notify` (it posts a real notification).

## Global Constraints

See the roadmap. Commands: `tab list [--json]`, `tab new [--name N] [--select] [-- COMMAND...]`, `tab read TAB [--lines N]`, `tab send TAB TEXT... [--key KEY]`, `tab select|rename|close TAB`, `diff [working|staged|base|REF]`, `notify MESSAGE...`, `status [--json]`, `skill install|uninstall|show`. `TAB` is a tab's name or 1-based index. `tab new` opens in the background (never steals the user's view) unless `--select`, refuses a name already in use, and types the command into a fresh shell so the tab outlives it; `tab close` refuses the last tab. Exit status 0 on success, 1 with a one-line message on stderr otherwise.

Sandbox rules (requests on `sandbox.sock`): what it starts runs in `sandboxCommand` (config.json; a command prefix read by `/bin/sh`), at the worktree; with no `sandboxCommand` nothing is started; it types only into panes it started that way (marked in the layout, `TerminalTab.sandboxed`); listing, reading, selecting, renaming and closing work on any tab.

## Review Focus

1. A fenced agent can't get an unsandboxed command run: every `sandbox.sock` path that starts a process wraps it in `sandboxCommand`, and `tab send` into an unmarked pane is refused — test on `CLIRequest.authorize(_:sandboxed:sandboxCommand:target:)`.
2. Two requests in one burst (`tab new dev` twice) never create two `dev` tabs — test on `WorktreeLayout.tabNamed`.
3. `tab read` of a tab whose pane died returns an error, not a hang — test on the zmx failure mapping.
4. Arguments with spaces, quotes or newlines survive CLI → JSON → app → zmx unchanged — round-trip test on `CLIRequest` encoding and `Zmx.sendArguments`.
5. The CLI with no app running prints "Yatty isn't running" and exits 1 within a second — test on the CLI's connect error mapping.

- [x] Task 1: protocol + CLI — `Sources/YattyCLI/main.swift` (new target `yatty-cli`), `Sources/Yatty/CLI/CLIProtocol.swift` shared by both via a small `YattyProtocol` target (`CLIRequest`, `CLIResponse`, socket paths), argument parsing tested in `Tests/YattyTests/CLITests.swift`; `make app` bundles it.
- [x] Task 2: app server — `Sources/Yatty/CLI/CLIServer.swift` (two `NWListener`s on Unix sockets), `Sources/Yatty/CLI/CLIHandler.swift` (ops → `AppStore` / zmx; sandbox rules); pane env `YATTY_CLI`, `YATTY_SOCKET`, PATH with the CLI's directory; tab names and indices; `tab new` in the background; snapshot-free (tested by running the CLI against a test server in `CLITests`).
- [x] Task 3: agents learn about it — a SessionStart hook prints a short note (only where `$YATTY_CLI` is set); `skills/yatty/SKILL.md` (when to use the CLI, the dev-server workflow, etiquette); `yatty skill install|uninstall|show` (`$CLAUDE_CONFIG_DIR` or `~/.claude/skills/yatty/`); README section "Running agents in fence" with the exact `allowUnixSockets` entry for `sandbox.sock`.
- [x] Task 4: verify (tests; a scripted end-to-end run of the CLI against the app's handler; fresh verifier; one re-verify), tick the roadmap, commit.
