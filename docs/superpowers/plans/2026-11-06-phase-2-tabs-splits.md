# Phase 2: Tabs and Splits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every worktree has tabs, every tab a tree of splits, every pane a Ghostty terminal with its own zmx session, laid out and restored exactly as left.

**Architecture:** A pure, Codable layout model (`SplitNode`, `TerminalTab`, `WorktreeLayout`) stored per worktree path in `state.json`. `AppStore` owns one `TerminalView` per pane, keyed by `PaneKey`, and applies layout operations; libghostty's keybinding actions arrive through `GhosttyApp.perform` and are routed to the pane they target. SwiftUI draws the tab bar and a recursive split view whose leaves re-host the long-lived terminal views.

**Tech Stack:** as in the roadmap; tests with Swift Testing (`import Testing`, `@testable import Yatty`).

**Spec:** roadmap `2026-11-06-agentree-port.md` (Phase 2) and agentree's tabs/splits behaviour (DEVLOG: "Tabs + pane splitting", "Keybindings", "Mouse").

## Status (resume here)

- Tasks 1–4 done and committed on `port`. Verifier: PASS on criteria 1–3, 6–9; its three minor findings (keyboard after rename, state.json writes during divider drags, untitled hidden tabs) are fixed but not re-verified.
- Still open: Task 4 Step 2 and Task 5's visual check. After a session restart with the window server allowed in fence (`macos.mach.lookup`: `com.apple.windowserver.active`, `com.apple.CARenderServer`): `make app && scripts/snapshot.sh tabs-splits` (and `worktrees`, `empty`); read the PNGs; if it prints `snapshot: 0 visible windows`, name the missing mach service to the owner. Then one re-verify round of the three fixes and the snapshots, and tick this plan.
- `knownSessions` lives on `Zmx` (not a free function as written below).

## Global Constraints

See the roadmap. In particular: pane `0` keeps the Phase 1 session name `yatty-<hash>`; other panes are `yatty-<hash>-<pane id>`; new `state.json` fields decode when missing.

## Review Focus

1. A Phase 1 `state.json` (no `layouts` key) loads with every repo intact — test in Task 2.
2. Relaunch with two tabs and a nested split restores the same tree and reattaches each pane without typing the agent command — Task 3 test on `WorktreeLayout` round-trip + `agentInput(for:)`.
3. Closing the focused pane moves focus to its sibling; closing the last pane of a tab removes the tab and selects its neighbour — Task 2 tests.
4. Directional focus in uneven nested splits picks the geometrically adjacent pane — Task 2 test.
5. Orphan reaping keeps every session referenced by any stored layout, including worktrees never opened this run — Task 2 test on `knownSessions`.

---

### Task 1: Test target and snapshot mode

**Files:**
- Modify: `Package.swift` (add `.testTarget(name: "YattyTests", dependencies: ["Yatty"], path: "Tests/YattyTests")`)
- Create: `Tests/YattyTests/SmokeTests.swift`
- Create: `Sources/Yatty/App/Snapshot.swift`
- Modify: `Sources/Yatty/App/YattyApp.swift` (start snapshot mode when `YATTY_SNAPSHOT` is set)
- Create: `scripts/snapshot.sh`
- Modify: `Makefile` (`test` target)

**Interfaces:**
- Produces: `enum Snapshot { static func scheduleIfRequested() }`. With `YATTY_SNAPSHOT=<png path>` it waits `YATTY_SNAPSHOT_DELAY` seconds (default 3), draws every visible window's content view with `bitmapImageRepForCachingDisplay` + `cacheDisplay` into one PNG (stacked if several), writes it, and terminates the app.
- Produces: `scripts/snapshot.sh <scene>` builds a throwaway sandbox (`XDG_CONFIG_HOME`, `HOME`-relative zmx dir untouched), a sample repo with worktrees, the scene's `state.json`, runs `build/Yatty.app/Contents/MacOS/Yatty` with `YATTY_SNAPSHOT=build/snapshots/<scene>.png`, and prints the path. Scenes: `empty`, `worktrees`, `tabs-splits`.

- [ ] Step 1: `SmokeTests.swift` — `@Test func directoryNameSanitizesBranch()` asserting `Git.directoryName(for: "feature/login page") == "feature-login-page"` and `Git.directoryName(for: "///") == "worktree"`.
- [ ] Step 2: `swift test --scratch-path .build/swift --disable-sandbox` → PASS (proves `@testable import Yatty` links GhosttyKit).
- [ ] Step 3: Snapshot mode + script; `scripts/snapshot.sh worktrees` → a PNG that shows the sidebar with the sample repo and its worktrees.

### Task 2: Layout model

**Files:**
- Create: `Sources/Yatty/Model/Layout.swift`
- Modify: `Sources/Yatty/Model/Models.swift` (`StoredState.layouts: [String: WorktreeLayout]`, custom `init(from:)` with `decodeIfPresent`)
- Modify: `Sources/Yatty/Services/Zmx.swift` (`sessionName(for:pane:)`)
- Create: `Tests/YattyTests/LayoutTests.swift`, `Tests/YattyTests/StateTests.swift`

**Interfaces (Produces):**
- `enum SplitAxis: String, Codable { case horizontal, vertical }` — horizontal = side by side (Ghostty `new_split:right`), vertical = stacked (`new_split:down`).
- `indirect enum SplitNode: Codable, Equatable { case pane(String); case split(SplitAxis, ratio: Double, first: SplitNode, second: SplitNode) }` with:
  - `var panes: [String]` (depth-first, first before second)
  - `func splitting(_ pane: String, with new: String, axis: SplitAxis, newFirst: Bool) -> SplitNode` (ratio 0.5)
  - `func removing(_ pane: String) -> SplitNode?` (parent collapses to the sibling; nil when the last pane goes)
  - `func settingRatio(_ ratio: Double, at path: [Bool]) -> SplitNode` (path: false = first, true = second; ratio clamped to 0.1…0.9)
  - `func equalized() -> SplitNode` (every ratio 0.5)
  - `func frames() -> [String: CGRect]` (unit square)
  - `func neighbor(of pane: String, toward direction: FocusDirection) -> String?` (nearest pane whose frame lies beyond `pane`'s edge in `direction` and overlaps it on the other axis)
- `enum FocusDirection { case left, right, up, down }`
- `struct TerminalTab: Codable, Identifiable, Equatable { var id: String; var root: SplitNode; var focusedPane: String; var name: String? }`
- `struct WorktreeLayout: Codable, Equatable { var tabs: [TerminalTab]; var selectedTab: String? }` with:
  - `static let initial` — one tab `t0` holding pane `0`, selected
  - `var allPanes: [String]`
  - `mutating func addTab(pane: String, id: String)` (inserted after the selected tab, selected)
  - `mutating func split(_ pane: String, new: String, axis: SplitAxis, newFirst: Bool)` (focuses `new`)
  - `mutating func close(_ pane: String)` (sibling — the pane nearest in the collapsed subtree — becomes focused; an emptied tab is removed and the next tab, else the previous, selected; no tabs → `selectedTab = nil`)
  - `func tab(containing pane: String) -> TerminalTab?`
- `func newPaneID() -> String` — 6 lowercase hex chars, random.
- `Zmx.sessionName(for worktreePath: String, pane: String) -> String` — `pane == "0"` → Phase 1 name, else `"<that>-<pane>"`.
- `func knownSessions(worktrees: [Worktree], layouts: [String: WorktreeLayout]) -> Set<String>` — each worktree's pane-0 session plus every pane of its stored layout.

- [ ] Step 1: Tests — `splitThenRemoveCollapses`, `removingLastPaneIsNil`, `ratioClampsAndFollowsPath`, `neighborInUnevenSplit` (tree: horizontal(0.3, a, vertical(0.5, b, c)) → `neighbor(of: "c", .left) == "a"`, `neighbor(of: "a", .right)` is `b` or `c` whichever overlaps a's centre row → `b` for top half), `closeFocusedPaneFocusesSibling`, `closingLastPaneOfTabSelectsNeighbour`, `phase1StateDecodes` (JSON `{"repos":[{"name":"r","path":"/x"}],"selectedWorktree":"/x"}` → one repo, empty layouts), `layoutRoundTrips`, `sessionNames` (`"0"` → `yatty-<10 hex>`, `"ab12cd"` → `yatty-<10 hex>-ab12cd`), `knownSessionsIncludeUnopenedLayouts`.
- [ ] Step 2: Run → FAIL (symbols missing). Step 3: implement. Step 4: Run → PASS.

### Task 3: Store — panes, operations, Ghostty actions

**Files:**
- Modify: `Sources/Yatty/Model/AppStore.swift`
- Modify: `Sources/Yatty/Ghostty/GhosttyApp.swift`
- Modify: `Sources/Yatty/Ghostty/TerminalView.swift`

**Interfaces:**
- Consumes: Task 2.
- Produces:
  - `struct PaneKey: Hashable { let worktree: String; let pane: String }`
  - `enum TerminalCommand { case newTab; case split(SplitAxis, newFirst: Bool); case close; case gotoSplit(GotoSplit); case gotoTab(GotoTab); case equalize; case title(String) }` with `enum GotoSplit { case previous, next, toward(FocusDirection) }`, `enum GotoTab { case index(Int), previous, next, last }`.
  - `TerminalView.paneKey: PaneKey?`, `TerminalView.onCommand: ((TerminalCommand) -> Void)?`, `TerminalView.onFocus: (() -> Void)?` (from `becomeFirstResponder`).
  - `AppStore.layout(for worktree: Worktree) -> WorktreeLayout` (stored or `.initial`)
  - `AppStore.terminal(for key: PaneKey, in worktree: Worktree) -> TerminalView?` (replaces `terminal(for:)`, same async start; the agent is typed only into pane `0` of a new session, or into a pane created by `newAgentTab`)
  - `AppStore.newTab(in: Worktree, agent: Bool)`, `split(_ key: PaneKey, axis:, newFirst:)`, `closePane(_ key: PaneKey)`, `closeTab(_ tabID: String, in: Worktree)`, `selectTab(_ tabID: String, in: Worktree)`, `focusPane(_ key: PaneKey)`, `setRatio(_:at:tab:in:)`, `renameTab(_:to:in:)`, `paneTitle(_ key: PaneKey) -> String?`
- GhosttyApp maps: `NEW_TAB` → `.newTab`; `NEW_SPLIT` RIGHT/DOWN/LEFT/UP → `.split(.horizontal,false)` / `.split(.vertical,false)` / `.split(.horizontal,true)` / `.split(.vertical,true)`; `GOTO_SPLIT` → `.gotoSplit`; `GOTO_TAB` (`PREVIOUS=-1`, `NEXT=-2`, `LAST=-3`, else 1-based) → `.gotoTab`; `CLOSE_TAB` → close the tab; `EQUALIZE_SPLITS` → `.equalize`; `SET_TITLE` → `.title`; `SHOW_CHILD_EXITED` and `close_surface_cb` → `.close`. Each returns true when it has a target surface.
- Removes: `endedSessions`, `restartSession` (an exited shell closes its pane, as in agentree).
- Teardown: `closeWorktree` / `removeRepository` / vanished worktrees kill every pane session of the layout and drop the layout; `reapOrphanSessions` uses `knownSessions`.
- Focus: split → new pane; close → the layout's new focused pane; tab switch → that tab's focused pane; worktree switch → no focus change (Return in the sidebar focuses the selected tab's focused pane).

- [ ] Step 1: Tests — `agentInputOnlyForFirstPaneOfNewSession` on `AppStore.agentInput(for pane: String, sessionIsNew: Bool, agentTab: Bool) -> String?` (a `static` helper), `gotoTabResolves` on `WorktreeLayout.tabID(for: GotoTab) -> String?` (wraps around for previous/next).
- [ ] Step 2: Run → FAIL. Step 3: implement. Step 4: Run → PASS; `make app` succeeds.

### Task 4: Views — tab bar and splits

**Files:**
- Create: `Sources/Yatty/Views/TerminalsView.swift` (tab bar, split view, empty state)
- Modify: `Sources/Yatty/Views/ContentView.swift` (DetailView uses `TerminalsView`; `TerminalHost` moves to `TerminalsView.swift`)

**Interfaces:**
- `TerminalsView(worktree: Worktree)`, `TabBar(worktree:layout:)`, `SplitNodeView(node:path:tab:worktree:)`, `PaneView(key:worktree:isFocused:dimmed:)`.
- Tab title: `tab.name ?? paneTitle(focused) ?? "Terminal"`, truncated in the middle at 24 characters; the selected tab is highlighted; × on the selected or hovered tab; double-click renames inline; `+` is a menu: New Shell, New Agent; at the right: Split Right, Split Down.
- Divider: 1pt line in the separator colour with a 6pt drag area; drag sets the ratio; double-click equalizes the tab.
- Unfocused panes, when a tab has more than one: overlay `Color.black.opacity(0.18)` that doesn't take hits.
- No tabs: `ContentUnavailableView("No Terminals", …)` with a "New Terminal" button.

- [ ] Step 1: Implement; `make app`.
- [ ] Step 2: `scripts/snapshot.sh tabs-splits` → PNG shows two tabs, the second selected with a horizontal split whose right half is split vertically; check alignment, truncation and dimming by eye.

### Task 5: Verify and commit

- [ ] Step 1: `swift test --scratch-path .build/swift --disable-sandbox` → PASS; `make app` → OK; snapshots for `empty`, `worktrees`, `tabs-splits`.
- [ ] Step 2: Fresh `verifier` agent: this plan's acceptance items (roadmap Phase 2) and Review Focus against the code, tests and snapshots. Fix what holds up; one re-verify round.
- [ ] Step 3: Tick Phase 2 in the roadmap, add the progress-log row, commit.
