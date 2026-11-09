# Sidebars rework: from a TUI's panels to a Mac app's

Mockups: `2026-11-09-sidebars-rework/sidebar-options.html` (option **A** is the
chosen one) and `2026-11-09-sidebars-rework/pr-panel.html`. They're HTML
fragments; open them in a browser.

## Why

Yatty's UI was ported from agentree, a TUI, and it shows. It isn't ugly. It
is clunky: it doesn't feel slick, and the sidebars are where that's worst.
They lay information out the way a terminal must, as packed text in
fixed-height lines with a cursor row. They hide actions behind keys and
context menus, and they make you read text where a glance would do. A real
GUI can do better: steady layouts, hover, inline editing, drag and drop,
tabs, buttons where the action is.

Success: using the two sidebars feels like a native Mac app (Mail, Xcode,
Finder), not like a TUI in a window. Nothing that works today gets harder.

## Goals

1. Rework the **left sidebar** (projects and worktrees) along option A.
2. Rework the **right sidebar** (the PR inspector): a fixed header holding a
   GitHub-style merge box, with tabs below it.

## Non-goals

- A visual restyle for its own sake. The look is fine; this is about how
  the sidebars work.
- The terminal area, its tab bar, and the sheets. They may get the same
  treatment later; this rework doesn't touch them, except the merge sheet
  (see "Merging").
- Changing what Yatty's concepts are: worktrees, agent states, the
  projects' grouping and folding stay as they are.

## Anti-goals: a failure even if it works

- A row that changes height, or rows that shift, because you clicked or
  hovered. (Rows coming and going because agents changed state is fine: the
  "Needs you" section does that by design, animated. My call on the reading.)
- Custom-drawn imitations of controls macOS already has: search fields,
  segmented controls, split buttons, text fields for renaming.
- Actions only reachable through a hidden gesture. Every action keeps a
  menu item and a command palette entry (the `Shortcuts` table and
  `CommandContext` rules stay the single source for menus and palette).
- Rebuilding TUI workarounds in Swift.
- A sidebar that takes noticeably more width from the terminal than today.

## Constraints

- SwiftUI on macOS 26, Swift 6.2. No new package dependencies.
- GitHub concepts use Octicons (`Sources/Yatty/Views/Octicon.swift`; add
  icons from @primer/octicons 19.15.0 the same way). macOS controls keep SF
  Symbols.
- New saved state goes in `StoredState` with tolerant decoding: a missing
  or unreadable field never loses the rest of state.json.
- Snapshot mode can't draw the `.sidebar` list style or Metal, and composites
  sheets below the window. Every new screen state gets a scene in
  `scripts/snapshot.sh` built from fixtures, as today.
- GitHub data comes from `gh`. Anything new the views need (check times,
  avatars) is fetched there, and failing to fetch it never breaks the panel.
- Fence: the user runs Yatty outside the sandbox, so the app may reach
  github.com. Tests and snapshots must not need the network.

## Left sidebar

What the user decided: **option A, with the filter**. The user also said
"looks right" to the details below, which were first proposed as guesses.

1. **Filter field at the top.** Typing narrows the list to worktrees whose
   name, branch or project matches. Projects with no match hide. Esc
   clears it. While it's empty, nothing changes.
2. **"Needs you" section** above the projects. It lists every worktree whose
   agent is in `needsAction`, from any project, with how long it has waited,
   longest wait first. It disappears when empty. Those worktrees also stay
   in their project. Done agents don't go here; they keep their marker in
   place. Rows enter and leave it animated. Clicking a row there selects that
   worktree, as anywhere else, but leaves its project folded or not as it
   was: selecting from this section doesn't unfold anything (my call;
   selections from elsewhere still unfold, as today). The bottom bar
   (`AgentCounts`) goes away, since this section replaces it.
3. **Every row is two lines, always.** Line one is the icon, the name and
   the status markers on the right. Line two is one useful fact, in words.
   Row height never depends on selection, hover or state.
4. **Hover shows actions** at the right of the row: ⋯ (a menu: rename, new
   worktree, open in Finder, copy path, and close for non-main worktrees)
   and ✕ (close the worktree, with today's confirmation; not on the main
   worktree; "Remove Directory…" for remote directories).
5. **Rename in place.** Double-click the name to edit it, ⏎ saves, Esc
   cancels. It saves the same label `renameWorktree` saves today (empty
   means "use the branch name"). The rename alert goes.
6. **Drag projects to reorder them** (repositories and hosts, each within
   its own kind). The order persists.
7. **Drop a folder on the sidebar to add it** as a repository, as
   "Choose Local Folder…" does.
8. **Project headers stay** as they are: chevron, icon, name, the summary
   when folded, and +.

**Amended 2026-11-09, after using it:** "Needs you" became three sections on
top — **Needs you**, **Working**, **Done** (finished, not yet seen) — and a
worktree in one of them moves there instead of being listed twice. Once its
agent goes idle (a finished one is seen) it sinks back into its project. In
each section, the longest in that state comes first.

### Row content

The second line picks the first of these that applies (my call on the order;
the user approved the examples "waiting 12m", "13 changes",
"PR #194 · checks failing", "merged · ready to close", "↓18 behind"):

1. The agent is waiting on you: "waiting 12m".
2. The PR needs attention: "PR #194 · checks failing", "PR #194 · changes
   requested", "merged · ready to close".
3. Agent working: "working".
4. Local changes and sync: "13 changes", "13 changes · ↑2", "↓18 behind".
5. The branch, when the name shown isn't the branch name.
6. Remote directory: `host:~/path`, or "disconnected".
7. Otherwise: "up to date".

Status markers on the right: the PR pill (Octicon for open/draft/merged and
`#N`, tinted by checks, as today's badge) and the agent dot (needs you,
working, done). At most these two, always in the same place.

## Right sidebar: the PR panel

What the user decided: **A's tabs, with B's merge box as the header**. The
user said "looks right" to the details below.

### Header (never scrolls)

- State chip (Octicon and Open/Draft/Merged/Closed), `#N`, and the title
  (a click opens the PR on GitHub).
- The author's avatar and login, `base ← head`, file count, `+N −M`.
- Refresh (↻ with "just now"/"2m ago") and open on GitHub (↗) as small
  icon buttons. The footer bar goes away.

### Merge box (part of the header)

One line each, every line a short verdict plus a muted detail:

- **Reviews:** the overall verdict ("Changes requested", "Approved",
  "Review required"), then who said what, and the reviewers' avatars.
  Clicking it opens the Conversation tab.
- **Checks:** "1 check failing" / "3 checks running" / "All checks passed",
  then which ones. Clicking it opens the Checks tab.
- **Conflicts:** "No conflicts with main" / "Conflicts with main" /
  "Checking…".
- **Merge split button.** The main part merges with the last-used method;
  the ▾ menu picks squash, merge or rebase (only the ones the repository
  allows). Whether it merges now, enables auto-merge or can't do either
  follows today's `PullRequests.mergeOptions` unchanged: when that says
  auto-merge (blocked or behind, and the repository allows it), the button
  reads "Enable Auto-Merge"; when neither, it's disabled and the line
  beside it gives the reason.
- **Once merged:** the box shrinks to one line, "Merged into main" in
  purple, with a **Close Worktree…** button that opens today's close
  confirmation (my call; it matches the sidebar's "merged · ready to
  close"). Closed without merging: one line, "Closed without merging", no
  button.

### Merging

The split button skips the merge sheet's first step (choosing): it opens
`MergeSheet` straight at its confirming step with the method it picked.
That step stays as it is: what will happen, the pin to the head commit,
Merge / Back. After it merges, the offer to close the worktree stays.
"Merge Pull Request…" in the menu bar and the palette keeps opening the
sheet at its choosing step, so a method can still be picked without the
mouse (my call).

### Tabs

A native segmented control under the header: **Conversation** (with the
comment count), **Checks** (with a red dot when one fails), **Description**.
Each worktree remembers its tab; Conversation is the default. The tab is
only remembered while the app runs (my call: not saved to disk).

- **Conversation:** PR comments and review summaries as chat bubbles, each
  with an avatar, a name and a relative time. Review threads appear as boxes
  under their `file:line`, with their comments inside. Resolved threads are
  folded and dimmed, as today. On top sits a line like
  "2 unresolved · 1 resolved hidden" and the **Review…** button that opens
  the comment review dialog (`CommentReviewSheet`). Markdown renders with
  `MarkdownText`. A click on a comment's time opens it on GitHub; this
  replaces today's hidden double-click.
- **Checks:** every check with its state icon, name and how long it took.
  Failed ones have a re-run button. A click on the name opens the log on
  GitHub. Failing checks first, then running, passed, skipped.
- **Description:** the body as markdown, then the labels.

## What exists now

- Left sidebar: `Sidebar`, `ProjectHeader`, `WorktreeRow`, `AgentCounts` in
  `Sources/Yatty/Views/ContentView.swift`. Folding is in `AppStore`
  (`foldedProjects`). `WorktreeRow` shows its second line only when
  selected; that rule is what goes.
- PR panel: `Sources/Yatty/Views/PullRequestInspector.swift` (folding
  sections and a footer), `PullRequestConversationViews.swift` (note and
  thread views), `MarkdownText.swift`, `CommentReviewSheet.swift`,
  `MergeSheet.swift`. The data lives in `PullRequestStore`, `PullRequests.swift` and
  `GitHub+PullRequests.swift`.
- Checks come from `statusCheckRollup` (`RawCheck`), which today has no
  start and end times. Reviews come from `latestReviews` and `reviewRequests`.
  `PullRequests.mergeStatus` already gives the merge verdict and its tone.

## Left to the builder

- Exact sizes, spacing, animations, and hover timing.
- The filter's shortcut. It must not collide with a terminal key: Ghostty
  binds ⌘F, so the shortcut needs to be something else, or ⌘F only while
  the sidebar has focus.
- How to fetch check durations (`startedAt`/`completedAt` on check runs) and
  how to re-run (GitHub Actions runs from the check's details URL, with
  `gh run rerun --failed`; hide the button when it isn't an Actions run).
- Avatars: load `https://github.com/<login>.png?size=64` (or the GraphQL
  `avatarUrl`), cache them in memory, and fall back to an initial in a
  coloured circle (always, in snapshots and tests).
- How inline rename, hover actions and drag and drop are built in SwiftUI,
  as long as the anti-goals hold.
- Splitting the work into steps; the left and right sidebars are
  independent.

## Calls made without the user

Settled in writing this up, open to change:

- The second line's order of facts (under "Row content").
- "Needs you" rows animate in and out; selecting from that section doesn't
  unfold projects.
- Merging keeps today's rule for merge now / auto-merge / blocked; the menu
  and palette keep the method-choosing step.
- A merged PR's box offers Close Worktree… (through today's confirmation).
- The PR tab is remembered per worktree only while the app runs.

## Verification

- Unit tests for: the second-line rules, filter matching, "Needs you"
  ordering, the merge box's verdict lines, the re-run target parsed from a
  details URL.
- Snapshot scenes for: the left sidebar with "Needs you" and a hover
  state, the filter in use, each PR tab, and merge-box states (blocked,
  ready, auto-merge, merged).
- A fresh reviewer per step, as with the port's phases.
