# Phase 3: Repositories and Worktrees from GitHub — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add repositories by picking any repo `gh` can see (cloned if needed), and start worktrees from a new branch, an existing branch, or an open pull request — agentree's add-repo and add-worktree flows.

**Architecture:** A `GitHub` service over the `gh` CLI (JSON in, small structs out) and more `Git` helpers; pure parsing and ranking functions unit-tested; two sheets (`AddRepositorySheet`, a reworked `NewWorktreeSheet`) driven by `AppStore`.

**Tech Stack:** as in the roadmap.

**Spec:** roadmap Phase 3; agentree `README.md` (Features: "Worktrees, not branches you switch between") and `docs/DEVLOG.md` ("Add / load worktree", `src/services/gh.ts`, `src/components/AddWorktreeModal.tsx` in agentree-tui).

## Status

Done. Verifier: PASS on 1–6; its one finding (fork PR branch name flipped once its worktree existed) fixed in `503ca7f` and re-verified. A fork PR's branch is always `pr/<n>-<head>` (deviates from Task 3's wording below).

## Global Constraints

See the roadmap. `Repo` gains `nameWithOwner: String?` and `StoredState` gains `labels: [String: String]` — both decode when missing. `config.json` gains `cloneDirectory` (default `~/yatty`, `~` expanded; the owner's is `~/agentree`).

## Review Focus

1. `gh` missing or logged out: the sheet says so (with `gh auth login`), never spins forever — test on `GitHub.errorMessage(for:)`.
2. Picking a repo whose clone folder already holds a *different* repo (two owners, same name): refused with a message, never added — test on `Git.remoteMatches(_:nameWithOwner:)`.
3. A PR from a fork whose head branch name already exists locally: the worktree's branch is `pr/<n>-<head>`, not the existing branch — test on `NewWorktreeChoice.branchName(for:existing:)`.
4. Remote URLs in every form gh/git produce (`git@github.com:o/r.git`, `https://github.com/o/r`, `ssh://git@github.com/o/r.git`, trailing slash) map to `o/r` — test on `Git.slug(fromRemote:)`.
5. Filtering 500+ repos while later pages still load keeps the ranking order stable — test on `RemoteRepo.ranked(_:query:)`.

---

### Task 1: GitHub service and parsing

**Files:** Create `Sources/Yatty/Services/GitHub.swift`, `Tests/YattyTests/GitHubTests.swift`; modify `Sources/Yatty/Services/Git.swift`, `Sources/Yatty/Model/Models.swift`.

**Interfaces (Produces):**
- `struct RemoteRepo: Identifiable, Hashable, Sendable, Decodable { let name: String; let nameWithOwner: String; let description: String?; let isPrivate: Bool }` (decoded from `/user/repos` JSON keys `name`, `full_name`, `description`, `private`); `var id: String { nameWithOwner }`; `static func ranked(_ repos: [RemoteRepo], query: String) -> [RemoteRepo]` — empty query keeps order; else score exact name 100 > name prefix 80 > name contains 60 > owner/name contains 40, drop 0, stable sort.
- `struct OpenPullRequest: Identifiable, Hashable, Sendable, Decodable { let number: Int; let title: String; let headRefName: String; let isCrossRepository: Bool; let author: Author }` with `struct Author: Hashable, Sendable, Decodable { let login: String }`; `var id: Int { number }`.
- `enum GitHub`:
  - `static func repoPage(_ page: Int) async throws -> (repos: [RemoteRepo], hasMore: Bool)` — `gh api "user/repos?per_page=100&page=<n>&sort=pushed&affiliation=owner,collaborator,organization_member"`; `hasMore` = page was full.
  - `static func openPullRequests(_ nameWithOwner: String) async throws -> [OpenPullRequest]` — `gh pr list -R <repo> --state open --limit 100 --json number,title,headRefName,isCrossRepository,author`.
  - `static func clone(_ nameWithOwner: String, to path: String) async throws` — `gh repo clone <repo> <path>`.
  - `static func errorMessage(for result: ProcessResult) -> String` — "gh isn't installed (brew install gh)" when the executable is missing (status 127 or stderr contains "No such file"), "gh isn't logged in: run `gh auth login`" when stderr mentions `auth login`, else trimmed stderr.
- `Git.slug(fromRemote url: String) -> String?` (`owner/name`, `.git` and trailing `/` stripped; GitHub hosts only); `Git.remoteSlug(root:) async -> String?` (`git remote get-url origin`); `Git.remoteMatches(_ url: String, nameWithOwner: String) -> Bool` (case-insensitive slug equality).
- `Git.listBranches(root:) async throws -> Branches` with `struct Branches: Equatable { var current: String?; var local: [String]; var remote: [String] }` — `for-each-ref --sort=-committerdate --format=%(refname) refs/heads refs/remotes`, remote `*/HEAD` skipped; `static func parseBranches(_ refs: String, current: String?) -> Branches` (pure, tested).
- `Git.addWorktree(root:path:existingBranch:) async throws` (`git worktree add <path> <branch>`; a remote branch `origin/x` checks out as local `x` with `--track`); `Git.fetchPullRequest(root:number:into branch:) async throws` (`git fetch origin +refs/pull/<n>/head:refs/heads/<branch>`).
- `Repo.nameWithOwner: String?`; `YattyConfig.cloneDirectory: String` (default `~/yatty`) and `var cloneRoot: URL` (tilde expanded).

- [x] Tests: `rankingOrdersByMatchQuality`, `rankingKeepsOrderForEmptyQuery`, `slugFromEveryRemoteForm`, `remoteMatchesIgnoresCase`, `branchesSkipRemoteHead`, `errorMessagesForMissingAndLoggedOutGh`, `repoJSONDecodes` (a 2-item `/user/repos` sample), `prJSONDecodes`.
- [x] Run → FAIL; implement; Run → PASS.

### Task 2: Add Repository sheet and cloning

**Files:** Create `Sources/Yatty/Views/AddRepositorySheet.swift`, `Sources/Yatty/Model/RepoCatalog.swift`; modify `AppStore.swift` (`addingRepository: Bool`, `addRemote(_:) async throws`, `addRepository(at:) async throws` used by both paths), `YattyApp.swift` (⌘O opens the sheet), `ContentView.swift` (sheet; empty-sidebar text).

**Interfaces:**
- `@MainActor @Observable final class RepoCatalog { var repos: [RemoteRepo]; var loading: Bool; var error: String?; func loadIfNeeded() }` — pages load one after another in the background; kept for the app's lifetime (re-opening shows at once, then refreshes).
- `AppStore.addRemote(_ repo: RemoteRepo) async throws`: an already-added repo (by `nameWithOwner`, else by clone path) is selected; else `<cloneRoot>/<name>`: cloned when missing; when present, accepted only if `Git.remoteMatches(origin, repo.nameWithOwner)`, else `GitError("<path> already holds another repository")`; then added with `nameWithOwner` and its main copy selected.
- Sheet: search field (focused), ↑↓ move the highlight, Return clones/adds the highlighted repo, Esc cancels; each row: name, `owner/name` secondary, lock for private, description one line; footer: "<n> repositories · loading more…" and "Choose Local Folder…"; while cloning: "Cloning owner/name…" with a spinner; errors inline with "Try Again".

- [x] `make app`; snapshot scene `add-repository` (catalog injected from a JSON fixture via `YATTY_REPO_FIXTURE`) shows the sheet with ranked rows.

### Task 3: New Worktree from a branch or a pull request; labels

**Files:** Modify `Sources/Yatty/Views/ContentView.swift` (move `NewWorktreeSheet` to `Sources/Yatty/Views/NewWorktreeSheet.swift`), `AppStore.swift`, `Models.swift`, `Sidebar` row.

**Interfaces:**
- `enum NewWorktreeChoice: Hashable { case newBranch(name: String, base: String); case existingBranch(String); case pullRequest(OpenPullRequest) }` with `static func branchName(for pr: OpenPullRequest, existing: Set<String>) -> String` (`headRefName` unless it exists locally and the PR is cross-repository → `pr/<number>-<headRefName>`) and `func directoryName() -> String`.
- `AppStore.createWorktree(in: Repo, choice: NewWorktreeChoice) async throws` (replaces the branch/base variant); a branch that already has a worktree selects that worktree instead.
- Sheet: segmented New Branch / Existing Branch / Pull Request. New Branch: name + base picker (local first, then remote, filterable; default `origin/HEAD`). Existing Branch: filterable list of local + remote branches without a worktree. Pull Request: open PRs (`#n title · author`), hiding those whose branch already has a worktree; a fetch error shows inline. Unavailable without `nameWithOwner` (local repo with no GitHub remote): the tab says why.
- Labels: `StoredState.labels: [String: String]` (worktree path → label); `AppStore.renameWorktree(_:to:)` (empty clears); sidebar row shows the label, else the branch leaf; context menu "Rename…", inline edit; closing a worktree drops its label.
- A worktree whose directory is gone shows "missing" and only offers Close.

- [x] Tests: `prBranchNameAvoidsExistingLocalBranch`, `labelsDecodeWhenMissing`, `choiceDirectoryNames`.
- [x] Run → FAIL; implement; Run → PASS; `make app`; snapshot scenes `new-worktree-branch`, `new-worktree-pr`.

### Task 4: Verify and commit

- [x] `make test`, `make app`, snapshots; fresh `verifier` agent on this plan + roadmap Phase 3 + Review Focus; fix; one re-verify round; tick the roadmap; progress-log row; commit.
