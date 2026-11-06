# Phase 5: Git Status and Pull Requests — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every worktree row says how dirty it is and what its pull request is doing; an inspector shows the PR in full and merges it — agentree's sidebar git line, PR badge, PR panel and merge dialog.

**Architecture:** Pure parsers and rules (git status, check states, merge status, merge options, "is this merged PR this branch's") unit-tested; `GitStatusMonitor` and `PullRequestStore` (both `@Observable`, owned by `AppStore`) poll on timers and on agent state changes; SwiftUI `.inspector` hosts the PR panel; the merge is a sheet.

**Tech Stack:** as in the roadmap; `gh` JSON, `AttributedString(markdown:)`.

**Spec:** roadmap Phase 5; agentree DEVLOG "PR panel", `src/services/pr.ts` (`PR_VIEW_FIELDS`, `checkState`, `summarizeChecks`, `mergeStatus`, `mergeOptions`, `mergePr`), `src/services/gh.ts` (`prForBranch`, `isThisBranchsPr`), `src/services/git.ts` (`status`).

## Status (resume here)

- Tasks 1–2 done: git status rows (`●N`, selected row's branch/+−/↑↓), PR badges (`PullRequestStore`, `GitHub+PullRequests.swift`), all pure rules for Tasks 2–4 in `PullRequests/PullRequests.swift` with tests; snapshot scene `status` (`YATTY_BADGE_FIXTURE`). `AppStore.showingPullRequest` exists; `PullRequestStore.refreshDetails`/`invalidate` and `GitHub.pullRequestDetails`/`mergeSettings`/`merge` exist.
- Next: Task 3 (inspector view, `.inspector`, ⌥⌘P, ⌘R, `ui.foldedSections`), Task 4 (merge sheet), Task 5.
- Snapshots run with `-ApplePersistenceIgnoreState YES` (they share the app's bundle id and would reopen at the real window's size).

## Global Constraints

See the roadmap. GitHub calls run only for repos with `nameWithOwner`, at most 4 `gh` processes at once, and network polling pauses while Yatty isn't the active app (local git polling continues). A failed refresh keeps the last good answer. Merging is never `--delete-branch` and always `--match-head-commit <the sha on screen>`.

## Review Focus

1. A merged PR from an older branch with the same name never shows on a new branch — test on `PullRequests.isThisBranchs(_:headIsAncestorOf:mergeCommitInBranch:headMatches:)`.
2. A blocked PR offers "when ready" only if the repo allows auto-merge; conflicts, drafts and finished PRs offer no merge and say why — test on `PullRequests.mergeOptions(_:settings:)`.
3. A refresh that fails (offline) keeps showing the last badge, not "no PR" — test on `PullRequestStore.apply(result:to:)`.
4. A repo without push access (GitHub omits `allow_*_merge`) still offers all three methods — test on `MergeSettings.decode`.
5. Binary files in `git diff --numstat` (`-\t-\tfile`) don't break +/− — test on `Git.parseNumstat`.

---

### Task 1: Git status in the sidebar

**Files:** Create `Sources/Yatty/Git/GitStatus.swift`, `Sources/Yatty/Git/GitStatusMonitor.swift`, `Tests/YattyTests/GitStatusTests.swift`; modify `ContentView.swift` (`WorktreeRow`), `AppStore.swift`.

**Interfaces:**
- `struct GitStatus: Equatable, Sendable { var changed: Int; var added: Int; var removed: Int; var ahead: Int; var behind: Int }`
- `Git.status(path:) async -> GitStatus?` (`status --porcelain`, `diff --numstat HEAD`, `rev-list --left-right --count @{upstream}...HEAD`; no upstream → 0/0); pure `Git.parsePorcelainCount(_:)`, `Git.parseNumstat(_:) -> (added: Int, removed: Int)`, `Git.parseAheadBehind(_:) -> (ahead: Int, behind: Int)`.
- `@MainActor @Observable final class GitStatusMonitor { private(set) var statuses: [String: GitStatus] }` — every 5s for every existing worktree (at most 4 at once), and right away when an agent's state changes.
- Row: `●N` (N changed files) after the label when N > 0; the selected row adds a second line: the branch when it isn't the label, `+a −r`, `↑ahead ↓behind` (each only when non-zero).

- [ ] Tests: `porcelainCountsLines`, `numstatSkipsBinaryFiles`, `aheadBehindParses`.

### Task 2: PR badge

**Files:** Create `Sources/Yatty/PullRequests/PullRequests.swift` (pure rules), `Sources/Yatty/PullRequests/PullRequestStore.swift`, `Sources/Yatty/Views/PullRequestBadge.swift`, `Tests/YattyTests/PullRequestTests.swift`.

**Interfaces:**
- `enum CheckState: String, Sendable { case pass, fail, pending, skipped }`; `struct RawCheck: Decodable { state, status, conclusion, name, context, detailsUrl, targetUrl }`; `PullRequests.checkState(_:)`, `PullRequests.summarize(_:) -> CheckState?` (agentree's rules verbatim).
- `struct BranchPullRequest: Equatable, Sendable { number; title; url; isDraft; merged: Bool; checks: CheckState?; headOid: String }`
- `GitHub.pullRequest(forBranch:in nameWithOwner:worktreePath:) async throws -> BranchPullRequest?` — `gh pr list -R … --head <branch> --state all --limit 5 --json number,title,url,isDraft,statusCheckRollup,state,headRefOid,mergeCommit,commits`; an open one wins; else a merged one only if `PullRequests.isThisBranchs(...)` (HEAD is its head or one of its commits, or HEAD is past its head; and its merge commit is not in the branch); throws on failure.
- `@MainActor @Observable final class PullRequestStore { private(set) var badges: [String: BranchPullRequest?]; func refresh(_ worktree: Worktree, in repo: Repo) }` — every 60s while active, on agent state change (at most every 15s per worktree), on ⌘R; `static func apply(result: Result<BranchPullRequest?, Error>, to old: BranchPullRequest??) -> BranchPullRequest??` (failure keeps old).
- Badge: `#N` tinted by checks (pass green, fail red, pending orange, none secondary); draft adds `◌`; merged `✓#N` purple; click opens the inspector.

- [ ] Tests: `checkStatesFollowRunAndStatus`, `summaryPrefersFailures`, `mergedPRMustBeThisBranchs`, `failedRefreshKeepsLastBadge`.

### Task 3: PR inspector

**Files:** Create `Sources/Yatty/PullRequests/PullRequestDetails.swift`, `Sources/Yatty/Views/PullRequestInspector.swift`; modify `ContentView.swift` (`.inspector`), `YattyApp.swift` (View ▸ "Show Pull Request" ⌥⌘P, "Refresh" ⌘R).

**Interfaces:**
- `struct PullRequestDetails: Decodable` — `gh pr view <n> -R <repo> --json number,title,url,state,isDraft,author,baseRefName,headRefName,headRefOid,additions,deletions,changedFiles,updatedAt,mergeable,mergeStateStatus,reviewDecision,latestReviews,reviewRequests,reviews,comments,labels,statusCheckRollup,body`, plus inline comments from `gh api repos/<repo>/pulls/<n>/comments?per_page=100` (best effort).
- `PullRequests.mergeStatus(_:) -> (label: String, tone: Tone)` with `enum Tone { good, warn, bad, muted, merged }` — agentree's table verbatim (Merged; Closed without merging; Draft; Merge conflicts with <base>; Branch is behind <base>; Blocked: changes requested / review required / failing checks / checks running / by branch protection; Mergeable, but some checks failed; Ready to merge; Checks running; Checking mergeability…).
- `PullRequests.relativeTime(_ iso: String, now: Date) -> String` ("just now", "5m ago", "3h ago", "2d ago", else yyyy-MM-dd).
- Inspector sections: header (`#N` state, title → opens URL, author, `base ← head`, `+a −r`, files); Merge (status, `Merge…` button); Reviews (decision glyph; each reviewer's latest verdict ✓ ✗ ● –; pending requests ◌); Checks (counts; failing first; click opens its log); Labels; Description (markdown); Comments (conversation, review summaries, inline with `file:line`; newest first; click opens). Sections fold by clicking their title; folded set stored in `state.json` `ui.foldedSections`. Footer: `↻ just now` / `refreshing…` / `failed`. Refresh every 30s while shown and active.

- [ ] Tests: `mergeStatusTable` (one case per row), `relativeTimeBuckets`, `detailsJSONDecodes` (fixture from a real `gh pr view` shape).
- [ ] Snapshot scene `pr-panel` (fixtures via `YATTY_PR_DETAILS_FIXTURE`).

### Task 4: Merge

**Files:** Create `Sources/Yatty/Views/MergeSheet.swift`; extend `PullRequests.swift`, `GitHub.swift`.

**Interfaces:**
- `struct MergeSettings: Equatable { var methods: [MergeMethod]; var autoMerge: Bool }`, `enum MergeMethod: String, CaseIterable { case merge, squash, rebase }`; `static func decode(_ json: [String: Any]) -> MergeSettings` (missing `allow_*` keys → all three offered).
- `PullRequests.mergeOptions(_ details:, settings:) -> (now: Bool, auto: Bool, reason: String?)` — ready/unstable/unknown → now; blocked or behind → auto when allowed; conflicts, drafts, merged/closed → reason.
- `GitHub.merge(number:repo:method:auto:headSha:) async throws` — `gh pr merge <n> -R <repo> --<method> [--auto] --match-head-commit <sha>`; never `--delete-branch`.
- Sheet: methods (last used first, stored `ui.mergeMethod`), a confirm step, progress, error; afterwards badges and details refresh and the done state offers "Close Worktree…".

- [ ] Tests: `mergeSettingsWithoutPushAccess`, `mergeOptionsPerState`.

### Task 5: Verify and commit

- [ ] `make test`, `make app`, snapshots (`worktrees` with statuses and badges, `pr-panel`, `merge`); fresh `verifier`; fix; one re-verify round; tick the roadmap; progress-log row; commit.
