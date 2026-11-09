# Sidebars Rework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the left sidebar and the PR inspector from TUI-style panels into native Mac sidebars, as the spec describes.

**Architecture:** Pure rules (row text, filter, "Needs you" order, merge-box verdicts, check timing, re-run target) go in small model files with unit tests. The views are rebuilt on top of them with native controls: `.searchable`, `Picker(.segmented)`, `Menu(primaryAction:)`, hover, inline `TextField`, drag and drop. Each task ends with a snapshot scene.

**Tech Stack:** Swift 6.2, SwiftUI/AppKit on macOS 26, Swift Testing, `gh`.

**Spec:** `docs/superpowers/specs/2026-11-09-sidebars-rework-design.md` (mockups in `docs/superpowers/specs/2026-11-09-sidebars-rework/`).

## Global Constraints

- macOS 26, Swift 6.2, no new package dependencies.
- GitHub concepts use `Octicon` (add SVGs from @primer/octicons 19.15.0, 16px, the way `Octicon.swift` holds them); macOS controls use SF Symbols.
- New saved state goes in `StoredState` with tolerant decoding (`decodeIfPresent` / `try?`).
- Every action keeps a menu item and a command palette entry; `Shortcuts` and `CommandContext` stay the single source.
- No shortcut may take a terminal key: Ghostty binds ⌘F (`start_search`).
- Sidebar column width stays `min: 200, ideal: 240, max: 400`.
- Snapshots and tests never touch the network; avatars fall back to initials there.
- A row's height never changes on click or hover; no rows shift because of a click or hover.
- Commits: short Conventional Commits, no attribution. Run `swift test --scratch-path .build/swift --disable-sandbox` before each (the two CLIServer socket tests fail under fence; nothing else may).
- Snapshots: build with `YATTY_APP=<scratch>/Yatty.app scripts/bundle-app.sh`, render with `YATTY_APP=… scripts/snapshot.sh <scene>`; never rebuild `build/Yatty.app` (the user runs it).

## Review Focus

1. **A filter that hides the selected worktree** must not change the selection or the terminal; clearing the filter shows the row selected again. (Task 2 test: `filterNeverTouchesSelection`.)
2. **A worktree listed twice** ("Needs you" and its project): clicking either selects it; only the clicked row looks selected; a selection made elsewhere (palette, ⇧⌘J) highlights the project row. (Task 2 test: `sidebarSelectionMapsNeedsYouRows`.)
3. **Inline rename** with an empty name goes back to the branch name; Esc leaves the label as it was; an agent state change mid-edit doesn't end the edit. (Task 2: empty case in `renameRules`; the rest by snapshot and review.)
4. **Merging while merge settings failed to load or details are stale** must never merge with a method the repository disallows: the button is disabled with the reason. (Task 4 test: `mergeButtonStates`.)
5. **No checks, no reviews, a PR from a fork, a deleted author (`author: null`)**: the merge box reads "No checks", "No reviews yet", and the author shows "ghost" with an initial. (Task 3 test: `mergeBoxEdgeCases`.)

---

### Task 1: Left sidebar rules

**Files:**
- Create: `Sources/Yatty/Model/WorktreeSummary.swift`
- Modify: `Sources/Yatty/Agents/AgentMonitor.swift` (keep each pane's report `since`)
- Modify: `Sources/Yatty/PullRequests/PullRequests.swift` (`BranchPullRequest.reviewDecision`), `Sources/Yatty/PullRequests/GitHub+PullRequests.swift` (ask `gh pr list` for `reviewDecision`)
- Modify: `Sources/Yatty/Model/AppStore.swift` (project moves, select without unfolding)
- Test: `Tests/YattyTests/SidebarTests.swift`

**Interfaces:**
- Produces:
  - `struct WorktreeFacts { var agent: AgentState?; var waitingSince: Date?; var pullRequest: BranchPullRequest?; var status: GitStatus?; var branch: String?; var label: String; var remotePath: String?; var disconnected: Bool }`
  - `enum WorktreeSummary { static func secondLine(_ facts: WorktreeFacts, now: Date) -> String; static func matches(_ query: String, name: String, branch: String?, project: String) -> Bool; static func needsYouOrder(_ waiting: [(id: String, since: Date)]) -> [String] }`
  - `AgentMonitor.waitingSince(of worktree: Worktree) -> Date?` (earliest `since` of its panes in `.needsAction`, nil otherwise)
  - `BranchPullRequest.reviewDecision: String?` (default nil; `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`)
  - `AppStore.moveProject(_ id: String, before target: String)` (repos among repos, hosts among hosts; other kinds or unknown ids do nothing; saves state)
  - `AppStore.select(_ id: String?, unfolding: Bool)` (`unfolding: false` sets the selection without the didSet's unfold)

- [ ] **Step 1: Write the failing tests** in `SidebarTests.swift`:

```swift
@Test func secondLineTakesTheFirstFactThatApplies() {
  let now = Date(timeIntervalSince1970: 10_000)
  func line(_ f: (inout WorktreeFacts) -> Void) -> String {
    var facts = WorktreeFacts(agent: nil, waitingSince: nil, pullRequest: nil, status: nil, branch: "main", label: "main",
                              remotePath: nil, disconnected: false)
    f(&facts); return WorktreeSummary.secondLine(facts, now: now)
  }
  let pr = BranchPullRequest(number: 194, title: "", url: "", isDraft: false, merged: false, checks: .fail, headOid: "")
  #expect(line { $0.agent = .needsAction; $0.waitingSince = now.addingTimeInterval(-720); $0.pullRequest = pr } == "waiting 12m")
  #expect(line { $0.agent = .needsAction; $0.waitingSince = now.addingTimeInterval(-20) } == "waiting <1m")
  #expect(line { $0.agent = .needsAction; $0.waitingSince = now.addingTimeInterval(-7_300) } == "waiting 2h")
  #expect(line { $0.pullRequest = pr } == "PR #194 · checks failing")
  #expect(line { var p = pr; p.checks = .pass; p.reviewDecision = "CHANGES_REQUESTED"; $0.pullRequest = p } == "PR #194 · changes requested")
  #expect(line { var p = pr; p.merged = true; $0.pullRequest = p } == "merged · ready to close")
  #expect(line { $0.agent = .working; $0.status = GitStatus(changed: 5) } == "working")
  #expect(line { $0.status = GitStatus(changed: 13, ahead: 2) } == "13 changes · ↑2")
  #expect(line { $0.status = GitStatus(changed: 1) } == "1 change")
  #expect(line { $0.status = GitStatus(behind: 18) } == "↓18 behind")
  #expect(line { $0.status = GitStatus(ahead: 3) } == "↑3 ahead")
  #expect(line { $0.label = "login"; $0.branch = "feature/login" } == "feature/login")
  #expect(line { $0.remotePath = "devbox:~/src/api" } == "devbox:~/src/api")
  #expect(line { $0.remotePath = "devbox:~/src/api"; $0.disconnected = true } == "disconnected")
  #expect(line { _ in } == "up to date")
}

@Test func filterMatchesNameBranchOrProject() {
  #expect(WorktreeSummary.matches("", name: "x", branch: nil, project: "p"))
  #expect(WorktreeSummary.matches("  LOG ", name: "login", branch: nil, project: "p"))
  #expect(WorktreeSummary.matches("feature/", name: "login", branch: "feature/login", project: "p"))
  #expect(WorktreeSummary.matches("flutter", name: "main", branch: "main", project: "sap-flutter-framework"))
  #expect(!WorktreeSummary.matches("zzz", name: "login", branch: "feature/login", project: "p"))
}

@Test func needsYouLongestWaitFirst() {
  let t = Date(timeIntervalSince1970: 1_000)
  #expect(WorktreeSummary.needsYouOrder([("a", t), ("b", t.addingTimeInterval(-60)), ("c", t.addingTimeInterval(30))]) == ["b", "a", "c"])
}

@MainActor @Test func projectsMoveWithinTheirKind() { /* AppStore built from a StoredState fixture (see StateTests for the pattern):
  repos [r1, r2, r3], hosts [h1, h2]:
  moveProject("/r3", before: "/r1") → repos order r3, r1, r2
  moveProject("ssh:h2", before: "ssh:h1") → hosts h2, h1
  moveProject("/r1", before: "ssh:h1") → unchanged */ }
```

  `GitStatus` gets a memberwise init with defaults if it lacks one. Write the last test concretely with whatever StateTests uses to build a store; if `AppStore` can't be built in a test, move the array logic into `static func moved(_ ids: [String], _ id: String, before target: String) -> [String]?` and test that instead.

- [ ] **Step 2: Run** `swift test --scratch-path .build/swift --disable-sandbox --filter SidebarTests`. Expected: build fails (types missing).
- [ ] **Step 3: Implement** the Interfaces above. `secondLine` follows the spec's order exactly (waiting → PR attention → working → changes/sync → branch when it differs from the label → remote path / "disconnected" → "up to date"); remote facts come before local git facts for remote worktrees (they have no git status). Durations: `<1m`, `Nm`, `Nh`, `Nd`, floor. `AgentMonitor` stores `report.since` per `PaneKey` next to `panes`. Add `reviewDecision` to the `gh pr list --json` fields and to `ListedPullRequest`.
- [ ] **Step 4: Run** the filter again, then the whole suite. Expected: PASS (bar the two socket tests).
- [ ] **Step 5: Commit** `feat(sidebar): row facts, filter and needs-you rules`.

### Task 2: Left sidebar views

**Files:**
- Create: `Sources/Yatty/Views/Sidebar.swift` (move `Sidebar`, `ProjectHeader`, `WorktreeRow` out of `ContentView.swift`; delete `AgentCounts`)
- Modify: `Sources/Yatty/Views/ContentView.swift` (drop the rename alert), `Sources/Yatty/Model/AppStore.swift` (`renamingWorktree` now starts an inline edit; `sidebarFilter: String`, not saved), `Sources/Yatty/Commands/AppStore+Commands.swift` + `Sources/Yatty/App/YattyApp.swift` (a "Filter Worktrees" command, ⌥⌘F), `scripts/snapshot.sh`
- Test: `Tests/YattyTests/SidebarTests.swift`

**Interfaces:**
- Consumes: everything Task 1 produces.
- Produces:
  - `enum SidebarSelection { static func tag(_ worktreeID: String, inNeedsYou: Bool) -> String; static func worktreeID(fromTag: String) -> String; static func isNeedsYou(_ tag: String) -> Bool }` (needs-you tags are `"needs-you:" + id`)
  - `Shortcuts.filterWorktrees = KeyboardShortcut("f", modifiers: [.command, .option])`

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func sidebarSelectionMapsNeedsYouRows() {
  #expect(SidebarSelection.tag("/r/a", inNeedsYou: true) == "needs-you:/r/a")
  #expect(SidebarSelection.worktreeID(fromTag: "needs-you:/r/a") == "/r/a")
  #expect(SidebarSelection.worktreeID(fromTag: "/r/a") == "/r/a")
  #expect(SidebarSelection.isNeedsYou("needs-you:ssh:devbox:/x"))
  #expect(!SidebarSelection.isNeedsYou("ssh:devbox:/x"))
}

@MainActor @Test func filterNeverTouchesSelection() { /* store with a selection; set sidebarFilter to a query that
  matches nothing; #expect(store.selection == before); clear it; still the same */ }

@MainActor @Test func renameRules() { /* renameWorktree(w, to: "") → label(for: w) == branch name;
  renameWorktree(w, to: "  ") → same; renameWorktree(w, to: "api") → "api" */ }
```

- [ ] **Step 2: Run** the filter. Expected: FAIL (missing `SidebarSelection`).
- [ ] **Step 3: Build the sidebar** to the spec's "Left sidebar" section:
  - `List(selection:)` bound through `SidebarSelection`: setting a needs-you tag calls `store.select(id, unfolding: false)`; a project-row tag calls `store.select(id, unfolding: true)`; the getter returns the needs-you tag only while the last click was there and `store.selection` is still that worktree, else the plain id.
  - `.searchable(text: $store.sidebarFilter, placement: .sidebar, prompt: "Filter")` with `.searchFocused` driven by the ⌥⌘F command; Esc clears (native). In snapshot mode (no split view) a plain `TextField` bound to the same text stands in. Filtering hides non-matching worktrees and projects with none left; "Needs you" filters too; folded projects with a match show unfolded while filtering.
  - "Needs you" `Section` first, hidden when empty, ordered by `needsYouOrder`, rows showing the project name and "waiting Nm"; insert/remove animated.
  - `WorktreeRow`: two lines always (`secondLine`), markers on the right (`PullRequestBadge` as a pill, then `AgentGlyph`). On hover the markers' slot shows ⋯ (`Menu`: Rename, New Worktree…, Open in Finder, Copy Path, Close Worktree… / Remove Directory…) and ✕ (`requestClose`; hidden for the main worktree) in the same width, so nothing moves.
  - Rename in place: `store.renamingWorktree = w` (from ⋯, the context menu, the palette or a double-click on the name) swaps the name for a focused `TextField`; ⏎ calls `renameWorktree`, Esc or losing focus without ⏎ cancels. ⏎ on a row that isn't being edited still focuses the terminal.
  - Project headers `.draggable(id)` and `.dropDestination(for: String.self)` → `moveProject`; the `List` takes `.dropDestination(for: URL.self)` → `addRepository(at:)` for each directory.
  - Remove `AgentCounts`; the ⇧⌘J command stays.
- [ ] **Step 4: Snapshot scenes** in `scripts/snapshot.sh`: `agents` (now shows "Needs you"), `sidebar-filter` (`YATTY_SNAPSHOT_FILTER=log`), `sidebar-hover` (`YATTY_SNAPSHOT_HOVER=<worktree id>` forces the hover state), `sidebar-rename` (`YATTY_SNAPSHOT_SHEET=sidebar-rename` starts an inline rename). Render all four plus `status`, `folded`, `ssh`; look at each.
- [ ] **Step 5: Run** the suite. Expected: PASS.
- [ ] **Step 6: Commit** `feat(sidebar): filter, needs you, steady rows, hover and inline rename`.

### Task 3: PR panel rules

**Files:**
- Create: `Sources/Yatty/PullRequests/MergeBox.swift`, `Sources/Yatty/Views/AvatarView.swift`
- Modify: `Sources/Yatty/PullRequests/PullRequests.swift` (`RawCheck.startedAt`, `completedAt`), `Sources/Yatty/PullRequests/GitHub+PullRequests.swift` (`rerunFailed`), `Sources/Yatty/PullRequests/PullRequestStore.swift` (merge settings cache)
- Test: `Tests/YattyTests/MergeBoxTests.swift`

**Interfaces:**
- Produces:
  - `struct MergeBoxLine: Equatable { var verdict: String; var detail: String; var tone: Tone }` (`Tone` is the existing enum: good, warn, bad, muted, merged)
  - `enum MergeBox { static func reviews(_ d: PullRequestDetails) -> MergeBoxLine; static func checks(_ d: PullRequestDetails) -> MergeBoxLine; static func conflicts(_ d: PullRequestDetails) -> MergeBoxLine; static func finished(_ d: PullRequestDetails) -> MergeBoxLine? }` (`finished` is non-nil for MERGED/CLOSED)
  - `RawCheck.duration: TimeInterval?` and `PullRequests.durationLabel(_ seconds: TimeInterval) -> String` ("8s", "1m 12s", "1h 3m")
  - `PullRequests.actionsRun(_ link: String) -> (nameWithOwner: String, runID: String)?`
  - `GitHub.rerunFailed(runID: String, in nameWithOwner: String) async throws` (`gh run rerun <id> --failed -R <repo>`)
  - `PullRequestStore.mergeSettings: [String: MergeSettings]` (by `Repo.id`) and `func loadMergeSettings(for repo: Repo) async`
  - `struct AvatarView: View { init(login: String?, size: CGFloat = 18) }` (a deleted author is `"ghost"`)

- [ ] **Step 1: Write the failing tests** (`details(...)` helper as in `PullRequestTests.swift`, extended with reviews/checks):

```swift
@Test func mergeBoxReviewLine() {
  // latestReviews: lead CHANGES_REQUESTED, reviewer APPROVED; reviewRequests: security-team
  #expect(MergeBox.reviews(d).verdict == "Changes requested")
  #expect(MergeBox.reviews(d).detail == "lead · reviewer approved · security-team waiting")
  #expect(MergeBox.reviews(d).tone == .bad)
  // reviewDecision APPROVED, one approval → "Approved", .good; REVIEW_REQUIRED, none → "Review required", .warn
}
@Test func mergeBoxCheckLine() {
  // FAILURE "unit tests", IN_PROGRESS "lint", SUCCESS "build" →
  //   verdict "1 check failing", detail "unit tests · lint running · build passed", tone .bad
  // two IN_PROGRESS → "2 checks running", .warn; all SUCCESS → "All checks passed", detail "3 passed", .good
}
@Test func mergeBoxConflictLine() {
  // mergeable MERGEABLE → "No conflicts" detail "with main" .good; CONFLICTING → "Conflicts" "with main" .bad; UNKNOWN → "Checking…" "" .muted
}
@Test func mergeBoxEdgeCases() {
  // no checks → checks verdict "No checks", .muted; no reviews and no decision → "No reviews yet", .muted
  // state MERGED → finished?.verdict == "Merged into main", tone .merged; CLOSED → "Closed without merging", .muted
}
@Test func checkDurationsAndRerunTargets() {
  #expect(PullRequests.durationLabel(8) == "8s")
  #expect(PullRequests.durationLabel(72) == "1m 12s")
  #expect(PullRequests.durationLabel(3_780) == "1h 3m")
  #expect(PullRequests.actionsRun("https://github.com/me/app/actions/runs/123/job/456")! == ("me/app", "123"))
  #expect(PullRequests.actionsRun("https://github.com/me/app/actions/runs/123")! == ("me/app", "123"))
  #expect(PullRequests.actionsRun("https://ci.example.com/build/9") == nil)
}
```

  (Write the commented cases as real `#expect`s with concrete `details(...)` values; tuples compare field by field.)
- [ ] **Step 2: Run** `--filter MergeBoxTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** `statusCheckRollup` already returns `startedAt`/`completedAt` for check runs; decode them as optional ISO strings. `AvatarView` loads `https://github.com/<login>.png?size=64` once per login through a `@MainActor` in-memory cache; while loading, on failure, in snapshot mode and for `"ghost"` it draws the login's first letter on a colour picked from the login's hash. `loadMergeSettings` uses `GitHub.mergeSettings` (snapshot mode already answers without the network) and keeps the last good value on failure.
- [ ] **Step 4: Run** the suite. Expected: PASS.
- [ ] **Step 5: Commit** `feat(pr): merge box verdicts, check timing, re-run and avatars`.

### Task 4: PR panel views

**Files:**
- Modify: `Sources/Yatty/Views/PullRequestInspector.swift` (header, merge box, tabs; delete the folding sections, `foldedSections` use and the footer), `Sources/Yatty/Views/PullRequestConversationViews.swift` (bubbles with avatars, the time opens GitHub), `Sources/Yatty/Views/MergeSheet.swift` (start at a given step and method), `Sources/Yatty/Model/AppStore.swift` (`mergingWorktree` → `mergeRequest`; `prTabs`), `Sources/Yatty/Commands/AppStore+Commands.swift`, `Sources/Yatty/App/YattyApp.swift`, `scripts/snapshot.sh`
- Test: `Tests/YattyTests/MergeBoxTests.swift`

**Interfaces:**
- Consumes: Task 3's `MergeBox`, `AvatarView`, `durationLabel`, `actionsRun`, `rerunFailed`, `mergeSettings`; `PullRequests.mergeOptions` unchanged.
- Produces:
  - `struct MergeRequest: Identifiable { var worktree: Worktree; var method: MergeMethod?; var id: String { worktree.id } }` (`method == nil` opens the sheet at choosing; otherwise at confirming with that method); `AppStore.mergeRequest: MergeRequest?` replaces `mergingWorktree`
  - `enum PullRequestTab: String, CaseIterable { case conversation, checks, description }`; `AppStore.prTabs: [String: PullRequestTab]` (by worktree id, not saved)
  - `enum MergeButton: Equatable { case merge(MergeMethod), autoMerge(MergeMethod), disabled(String) }` and `static func MergeBox.button(_ d: PullRequestDetails, settings: MergeSettings?, lastMethod: MergeMethod?) -> MergeButton`

- [ ] **Step 1: Write the failing test:**

```swift
@Test func mergeButtonStates() {
  // settings nil → .disabled("Loading merge options…")
  // CLEAN, methods [.squash, .merge], last .rebase (not allowed) → .merge(.squash) (first allowed)
  // CLEAN, last .merge allowed → .merge(.merge)
  // BLOCKED, autoMerge true → .autoMerge(<method>); BLOCKED, autoMerge false →
  //   .disabled("<mergeStatus label> — and auto-merge is off for this repo")
  // CONFLICTING → .disabled("Merge conflicts with main"); draft → .disabled("Draft — not ready for review")
}
```

  (Concrete `#expect`s; the reasons come from `mergeOptions` so they match today's sheet.)
- [ ] **Step 2: Run** `--filter mergeButtonStates`. Expected: FAIL.
- [ ] **Step 3: Implement** `MergeBox.button` on top of `mergeOptions`, then the views to the spec's "Right sidebar" section:
  - Header pinned above a `ScrollView`: state chip (Octicon + label), `#N`, title button (opens GitHub), `AvatarView` + login, `base ← head`, files, `+N −M`, then ↻ (with `relativeTime` of `detailsRefreshed`) and ↗ as borderless icon buttons.
  - Merge box under it: `MergeBox` lines with tone colours and reviewer avatars; the reviews line sets the tab to `.conversation`, the checks line to `.checks`. Then the split button: `Menu(primaryAction:)` whose label is "Squash and Merge" / "Merge" / "Rebase and Merge" or "Enable Auto-Merge", menu items for the allowed methods (picking one sets `store.mergeMethod`), disabled with the reason beside it for `.disabled`. Its action sets `store.mergeRequest = MergeRequest(worktree:, method:)`. `finished` replaces the box with its one line, plus **Close Worktree…** (`requestClose`) when merged and the worktree isn't main.
  - `Picker("", selection:)` with `.segmented`: "Conversation N", "Checks" (with a red dot via a failing-count label when one fails), "Description"; bound to `prTabs[worktree.id] ?? .conversation`.
  - Conversation: the summary line ("2 unresolved · 1 resolved hidden") and Review… on top, then notes and threads (existing views; notes become bubbles with `AvatarView`; the relative time is a link button to the comment's URL; the double-click goes).
  - Checks: rows sorted fail, pending, pass, skipped: state icon, name (link), `durationLabel`, and for failed ones with an `actionsRun` target a ↻ button that calls `rerunFailed` then `refreshDetails`; errors go to `store.alert`.
  - Description: `MarkdownText` then labels; "No description." when empty.
  - `MergeSheet(worktree:, method:)`: `method != nil` starts at `.confirming` with it. Menu and palette "Merge Pull Request…" set `MergeRequest(worktree:, method: nil)`. `.task` in the inspector calls `loadMergeSettings` for the repo.
- [ ] **Step 4: Snapshot scenes:** `pr-panel` (Conversation; auto-merge state, since snapshot merge settings allow it), `pr-checks` and `pr-description` (`YATTY_SNAPSHOT_PR_TAB`), `pr-ready` (fixture with `mergeStateStatus` CLEAN), `pr-merged` (state MERGED), `merge` (sheet from the menu path). Render and look at each.
- [ ] **Step 5: Run** the suite. Expected: PASS.
- [ ] **Step 6: Commit** `feat(pr): merge box header and tabs`.

### Task 5: Finish

**Files:**
- Modify: `README.md` (Keys: ⌥⌘F filter; sidebar and PR panel descriptions), `docs/superpowers/plans/2026-11-09-sidebars-rework.md` (tick the boxes, a progress line per task)
- Test: none new.

- [ ] **Step 1:** Palette and menus: every action from Tasks 2 and 4 is in both (Filter Worktrees, Rename, Close, Merge…, Review Comments…, Show Pull Request); `CommandTests` still pass.
- [ ] **Step 2:** Render every snapshot scene once more and look at all of them side by side for leftovers of the old style (fold arrows in the inspector, text glyphs, the footer).
- [ ] **Step 3:** One fresh reviewer over the whole branch; fix what holds up; one re-review.
- [ ] **Step 4: Commit** `docs: sidebars rework done`.
