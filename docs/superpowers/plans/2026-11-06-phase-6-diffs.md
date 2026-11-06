# Phase 6: Diffs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open a worktree's changes — working, staged, against the base branch, a ref, or a range of commits — in the user's diff viewer, in a tab of its own that closes when the viewer quits. agentree's `⌥d`.

**Architecture:** Pure `DiffViewers` (agentree's `src/services/diff.ts` verbatim: targets → `git diff` args, viewer commands, empty-diff guard, `LESS=R`, commit-range picking) unit-tested; a `DiffSheet` (picker + viewer choice + commit list); `AppStore.newTab(in:command:name:)` starts a tab whose zmx session runs `/bin/sh -c <command>` instead of a login shell, with the user's login `PATH`, so the tab's pane closes when the command exits.

**Spec:** roadmap Phase 6; agentree DEVLOG "Diff viewers", `src/services/diff.ts`, `git.ts branchCommits`.

## Status

- Done (`dd8fb77`): verified with no findings.

## Global Constraints

See the roadmap. Viewers: hunk, diffnav (needs delta), delta, difftastic (`difft`), lumen, nvim diffview (only when chosen), plain git — the first installed of hunk, diffnav, delta, difftastic, lumen by default, else git; the choice is remembered in `state.json` `diffViewer`. Pagers get `LESS=R` and the user's `core.pager` is overridden. An empty diff prints "No changes to show." and waits for Enter.

## Review Focus

1. A pager can't quit on a short diff (git's default `LESS=FRX` has `-F`) — test on the generated commands containing `LESS=R`.
2. The user's own `core.pager` (often delta) never applies to "plain git" or difftastic — test on `-c core.pager=…` in their commands.
3. A ref or range with spaces or quotes stays one argument — test on `DiffViewers.command(_:args:)` quoting.
4. A commit range picked oldest→newest and newest→oldest gives the same `parent..newer` range — test on `DiffViewers.pickCommits`.
5. A root commit (no parent) diffs against the empty tree — test on `Git.parseCommits` with the empty-tree sha passed in.

- [x] Task 1: `Sources/Yatty/Diffs/DiffViewers.swift` + `Tests/YattyTests/DiffTests.swift` — `enum DiffTarget { case working, staged, base(String), ref(String), range(String) }` (`args`), `enum DiffViewer: String, CaseIterable { hunk, diffnav, delta, difftastic, lumen, diffview, git }` (`needs`, `auto`, `label`, `command(args:)`), `DiffViewers.command(_:args:) -> String` (the guarded `sh -c` script), `available(in path:)`, `resolve(_:available:)`, `next(after:available:)`, `struct Commit { sha, short, parent, subject }`, `pickCommits(_:cursor:mark:) -> (range: String, label: String)?`, `Git.parseCommits(_:emptyTree:)`, `Git.branchCommits(path:base:)`, `Run.loginPath()` (`<login shell> -l -c env`, cached; falls back to `Run.searchPath`).
- [x] Task 2: `AppStore.newTab(in:command:name:)` and pane commands (`commandPanes`), `Zmx.attachCommand(session:command:)`; `DiffSheet` (Working changes / Staged / vs base / Specific ref… / Commits…, viewer menu, Return opens), Terminal menu "Open Diff…" ⌥⌘D and the tab bar `+` menu "New Diff…"; snapshot scene `diff`.
- [x] Task 3: verify (tests, app, snapshots, fresh verifier, one re-verify), tick the roadmap, commit.
