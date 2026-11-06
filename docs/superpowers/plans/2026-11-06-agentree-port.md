# Yatty: agentree Port — Roadmap

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (the owner chose native execution: implement each phase in-session, then a fresh `verifier` agent checks it). Each phase gets its own detailed plan, `docs/superpowers/plans/<date>-phase-<n>-<topic>.md`, written when the phase starts. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Yatty does everything agentree-tui does for its user, as a native macOS app where every terminal is a real Ghostty terminal.

**Architecture:** One SwiftPM executable target (`Sources/Yatty`): SwiftUI app shell, AppKit `TerminalView`s rendered by GhosttyKit (libghostty), `AppStore` holding state, and small services that run `git`, `gh` and `zmx` as processes. Pure logic is unit-tested with Swift Testing through `@testable import Yatty`. zmx keeps every pane's process alive across app restarts; tabs and splits are Yatty's own native layout.

**Tech Stack:** Swift 6 (tools 6.2), SwiftUI + AppKit, macOS 26+, GhosttyKit built from `ThirdParty/ghostty` @ `16f5674`, zmx 0.8.1, git, gh.

**Spec:** agentree-tui's user-facing behaviour, in `/Users/ignacywaluzenicz/agentree/agentree-tui/README.md` and `/Users/ignacywaluzenicz/agentree/agentree-tui/docs/DEVLOG.md` (repo `BeerHobbyist/agentree-tui`). Yatty copies the concepts, not the implementation (see `CLAUDE.md`).

## Resuming in a new session

1. Read `CLAUDE.md`, this file, and the plan of the first phase below that isn't checked.
2. `git log --oneline` shows what landed; the progress log at the bottom maps commits to phases.
3. Build: `make deps` (only after a Ghostty bump; needs zig 0.17 and Xcode's Metal toolchain, outside fence), `make app`, `swift test --disable-sandbox`.

## Global Constraints

- macOS 26+, Apple Silicon (GhosttyKit is built `-Dxcframework-target=native`).
- No tmux. One zmx session per terminal pane, `ZMX_DIR=~/.local/state/yatty/zmx`, `ZMX_NO_DETACH_KEY=1`. A worktree's first pane (id `0`) is session `yatty-<first 10 hex of sha256(worktree path)>`; any other pane is `yatty-<that hash>-<pane id>`.
- libghostty runs a surface's `command` as `bash -c "exec -l <command>"`: pass plain shell-quoted words, no `shell:`/`direct:` prefix.
- C callbacks handed to libghostty are built in `nonisolated` code. Closures written in main-actor code get a runtime executor check that kills the app when libghostty calls them from its own threads.
- Fenced agents never reach zmx's sockets (zmx runs commands outside the sandbox, as tmux did). Agents' requests go through the app.
- Ghostty's own keybinds drive terminal actions (`new_tab` ⌘T, `new_split` ⌘D / ⌘⇧D, `close_surface` ⌘W, `goto_split` ⌘[ ⌘] ⌘⌥←↑↓→, `goto_tab` ⌘1–9, ⌘⇧[ ⌘⇧]). Yatty handles the actions libghostty emits for them.
- Every new field in `state.json` decodes when missing (`decodeIfPresent`): an undecodable state file is moved aside and loses the user's repo list.
- Build with `swift build ... --disable-sandbox` (SwiftPM's manifest sandbox can't nest inside fence); test with `swift test --scratch-path .build/swift --disable-sandbox`.
- Commits: short Conventional Commits, no co-author trailers.

## Review Focus

1. **Relaunch**: quitting and reopening reattaches every pane of every tab of every worktree, in the same layout, and never types the agent command into an existing session.
2. **Teardown**: closing a pane, tab, worktree or repository kills exactly its sessions; nothing else, and nothing left orphaned.
3. **Keyboard focus**: after a split, a close, a tab switch or a worktree switch, keys land in the terminal the user expects, never in a hidden one.
4. **Odd names**: branch names, repo paths and tab names with spaces, quotes, `#`, `;` or non-ASCII survive every shell layer (Ghostty's bash, zmx argv, git, gh).
5. **No network or no `gh` login**: every GitHub feature degrades to a clear message; nothing hangs the UI or crashes.

## Verifying a phase

- `swift test --scratch-path .build/swift --disable-sandbox` passes.
- `make app` succeeds.
- `scripts/snapshot.sh <scene>` renders the app window with sample data to `build/snapshots/<scene>.png`. Needs fence's `macos.mach.lookup` to allow `com.apple.windowserver.active` and `com.apple.CARenderServer`. In snapshot mode the window is laid out as a plain sidebar | detail row and panes are placeholders (the real split view's sidebar and libghostty can't be drawn or started there). A fresh `verifier` agent checks the phase's acceptance list against the code and those images.
- The owner runs the app and confirms what snapshots can't show.

---

## Phase 1 — App shell and worktrees ✅

- [x] GhosttyKit + zmx build pipeline (`make deps`, `make app`).
- [x] Repositories added from a local folder; worktrees read from `git worktree list`.
- [x] New worktree on a new branch in `<repo>/.worktrees/<branch>` (base: `origin/HEAD`); close (deletes the directory, keeps the branch); remove repository (files untouched).
- [x] One Ghostty terminal per worktree, kept alive while hidden, persistent through zmx; a new session types `agentCommand` from `~/.config/yatty/config.json`.
- [x] Reviewed twice; startup crash (main-actor executor check in C callbacks) fixed.

## Phase 2 — Tabs and splits ✅

Plan: `2026-11-06-phase-2-tabs-splits.md`.

- [x] Each worktree has tabs; each tab is a tree of splits; every pane a Ghostty terminal with its own zmx session.
- [x] The layout (tabs, splits, ratios, names, focused pane) persists in `state.json` and is restored on launch.
- [x] Ghostty keybinds: new tab, split right/down, close pane, go to split (prev/next/direction), go to tab (n/prev/next/last), equalize splits.
- [x] Tab bar: tabs titled by the focused pane's terminal title (or a name the user gave), close button, `+` menu (New Shell / New Agent), split buttons, double-click to rename.
- [x] Dividers drag to resize; unfocused panes are dimmed.
- [x] Closing a pane kills its session; closing the last pane leaves "No Terminals" with a button to open one.
- [x] `scripts/snapshot.sh` and the in-app snapshot mode exist (used by every later phase).

## Phase 3 — Repositories and worktrees from GitHub ✅

Plan: `2026-11-06-phase-3-github-worktrees.md`.

- [x] Add Repository (⌘O) lists every repo `gh` can see (owned, collaborator, organization; most recently pushed first; paged in the background), ranked filter (exact name > prefix > contains > owner/name contains), clones with `gh repo clone` into `cloneDirectory` (config; default `~/yatty`), or reuses an existing clone; "Choose Local Folder…" stays.
- [x] New Worktree offers: a new branch from a base picked from local and remote branches; an existing branch; an open pull request (fetched as `refs/pull/<n>/head`, forks included; our own PR's branch is its head branch, a fork's is always `pr/<n>-<head>` so it can't clash or change), hiding PRs that already have a worktree.
- [x] Worktree labels: rename a worktree's display name (stored by worktree path); branch and directory unchanged.
- [x] A worktree whose directory vanished shows as missing and can be closed.

## Phase 4 — Agent status and notifications ✅

Plan: `2026-11-06-phase-4-agent-status.md`.

- [x] Agents Yatty starts run with Claude Code hooks (a `--settings` file under `~/.config/yatty/`) writing `<state> <epoch>` per pane under `~/.config/yatty/agents/`: needs you, working, done, idle.
- [x] Optional "Track every claude": the same hooks merged into `~/.claude/settings.json` (asks first, reversible, idempotent), inert outside Yatty.
- [x] Sidebar shows each worktree's most urgent agent status, animated (working spins, needs-you pulses); "done" clears once viewed; stale reports corrected against pane activity.
- [x] A system notification when an agent needs you or finishes while you aren't looking at it; clicking it opens that worktree and pane.
- [x] "Next agent that needs you" command with a shortcut, and agent counts in the sidebar footer.

## Phase 5 — Git status and pull requests ✅

Plan: `2026-11-06-phase-5-git-status-prs.md`.

- [x] Sidebar: uncommitted-file count, and for the selected worktree: branch, +/−, ahead/behind; refreshed every 5s and on agent state changes.
- [x] PR badge per worktree (open PR for the branch, else a merged one that was this branch's), coloured by CI, draft and merged variants; refreshed every 60s, paused while the app is inactive.
- [x] PR inspector (right side): merge status, reviews, checks (failing first, click opens the log), labels, description (markdown), comments (newest first, inline ones with file:line); open on GitHub; refresh; foldable sections remembered.
- [x] Merge: methods the repo allows, the last one used first; auto-merge when blocked; confirm step; `gh pr merge --match-head-commit <sha>`; afterwards offers to close the worktree.

## Phase 6 — Diffs ✅

Plan: `2026-11-06-phase-6-diffs.md`.

- [x] Diff picker: working changes, staged, against the base branch, a ref, or a range of commits picked from a list.
- [x] Viewers: hunk, diffnav, delta, difftastic, lumen, nvim diffview, plain git — the first installed by default, choice remembered; opens in a tab of its own that closes when the viewer quits; an empty diff says so; pagers can't quit on a short diff.

## Phase 7 — Agent CLI and fence ✅

Plan: `2026-11-06-phase-7-agent-cli.md`.

- [x] A `yatty` CLI bundled in the app, on the PATH of every Yatty terminal, talking to the app over its socket: `tab list|new|read|send|select|rename|close`, `diff`, `notify`, `status` (`--json` where agentree has it), `skill install|uninstall|show`.
- [x] Agents Yatty starts are told about the CLI by a silent-except-SessionStart hook; a Claude Code skill ships with it.
- [x] Inside fence the CLI's requests run on the sandbox's terms: started commands wrapped in `sandboxCommand` (config), typing only into panes started that way, no argument tmux/zmx could turn into a command.

## Phase 8 — SSH projects ✅

Plan: `2026-11-06-phase-8-ssh.md`.

- [x] Add an SSH host (typed or from `~/.ssh/config`) and directories on it; their terminals run there, kept alive by zmx on the host (install hint when missing); one shared connection per host (ControlMaster, short ControlPath).
- [x] Password or key-passphrase logins through `SSH_ASKPASS`, never stored; background calls never log in on their own.

## Phase 9 — Command palette, help and polish (in progress)

Plan: `2026-11-06-phase-9-polish.md`.

- [ ] Command palette (⇧⌘P) listing every action that applies, fuzzy-filtered.
- [ ] Settings window for `agentCommand`, `cloneDirectory`, `sandboxCommand`, notifications.
- [ ] Help / keyboard reference; README with screenshots; release build (`make app CONFIG=release`).

---

## Progress log

| Date | Phase | Commit |
|---|---|---|
| 2026-11-06 | 1 — app shell and worktrees | `e19b370` |
| 2026-11-06 | 2 — tabs and splits (two verifier rounds; snapshots checked) | `8504a15`…`ecfbb85` |
| 2026-11-06 | 3 — repositories and worktrees from GitHub (verifier + re-verify) | `16ad5ae`…`503ca7f` |
| 2026-11-06 | 4 — agent status and notifications (verifier + re-verify) | `c8d8216`…`040e347` |
| 2026-11-06 | 5 — git status and pull requests (verifier + re-verify) | `aa039ab`…`dd8fb77` |
| 2026-11-06 | 6 — diffs (verifier: no findings) | `dd8fb77` |
| 2026-11-06 | 7 — agent CLI and fence (verifier: 6 findings fixed, re-verified; real-app e2e) | `a59a99e`…`ad964b4`+ |
| 2026-11-06 | 8 — SSH projects (real-sshd e2e; verifier: 9 findings fixed, re-verified, 2 more fixed) | `728c90d`…`2bb4b0e` |
