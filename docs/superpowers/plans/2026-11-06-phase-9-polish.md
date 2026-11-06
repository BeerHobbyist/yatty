# Phase 9: Command Palette, Settings, Help and Release — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nothing needs remembering: every action is in a searchable command palette that shows its shortcut, every shortcut is in a help window, and the settings people change are a window instead of a JSON file. Then a release build and a README with screenshots. agentree's `ctrl+p` palette, `?` help and README.

**Architecture:** One list of actions, `Command { id, title, group, shortcut?, detail?, isEnabled, run }`, built from the store's state (`AppStore.commands`), drives the palette and the help window, so neither can drift from what the menus do. The palette is a sheet over the window (⇧⌘P, Ghostty's and VS Code's palette key; also Ghostty's `toggle_command_palette` action, so a rebound key works. Not ⌘K: menus win over terminal keys, and ⌘K is the terminal's clear screen): a field, a grouped list, ↑↓ and ⏎, a click runs. agentree's matching verbatim (`matchScore`: start 100, word start 80, inside 60, letters in order 20, else 0; the title counts double against the group). "Go to <worktree>" for every worktree and remote directory, and "Go to tab <n>" for the selected worktree's tabs. A SwiftUI `Settings` scene (⌘,) edits `config.json` (`agentCommand`, `cloneDirectory`, `sandboxCommand`, `notifications`), and `AppStore.config` becomes a stored property updated on save. Help (⌘?) is a window listing every command's shortcut by group, plus Ghostty's own terminal keys.

**Spec:** roadmap Phase 9; agentree DEVLOG "Command palette", "Hints", `src/components/CommandPalette.tsx` (`matchScore`, `filterCommands`), `src/components/HelpOverlay.tsx`, README.

## Global Constraints

See the roadmap. Commands appear only when they apply: no "Close Worktree" on a main copy, no "Merge" without an open PR, no diff or PR on a remote directory. A command's shortcut is the menu's own (from one table, `Shortcuts`), never a second binding. Settings write `config.json` atomically and keep keys they don't know. `sandboxCommand` changes apply to panes started after the change. The release build is `make app CONFIG=release`, ad-hoc signed.

## Review Focus

1. The palette never offers what the menus would refuse — test that `AppStore.commands` and the menu `disabled` rules agree, through a shared `isEnabled`.
2. Matching: agentree's order — test `CommandPalette.matchScore` and `filter` with its cases (prefix beats word start beats inside beats letters in order; title counts double).
3. Settings round-trip: unknown keys in `config.json` survive a save; a blank `cloneDirectory` falls back to the default; a blank `sandboxCommand` means none — test on `ConfigFiles.saveConfig`.
4. Keyboard: the palette opens over a focused terminal and gives the keyboard back to it on close; ⏎ on a filtered list runs the highlighted command, not the first unfiltered one.

- [ ] Task 1: `Sources/Yatty/Commands/Commands.swift` (`Command`, `Shortcuts`, `AppStore.commands`, `matchScore`, `filter`) + `Tests/YattyTests/CommandTests.swift`; the menus read their shortcuts and enabled rules from it.
- [ ] Task 2: `CommandPalette` sheet (⇧⌘P and Ghostty's palette action; View menu "Command Palette…"), focus handed back; snapshot scene `palette` (empty and filtered).
- [ ] Task 3: `SettingsView` (`Settings` scene, ⌘,), `ConfigFiles.saveConfig` keeping unknown keys, `AppStore.config` live; Help window (⌘?) from `AppStore.commands` and Ghostty's keys; snapshot scenes `settings`, `help`.
- [ ] Task 4: README (what Yatty is, install, first steps, keys, SSH, the CLI, fence) with screenshots from the snapshot scenes in `docs/screenshots/`; `make app CONFIG=release` checked; fresh verifier, one re-verify; tick the roadmap; commit.
