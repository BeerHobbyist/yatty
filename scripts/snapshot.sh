#!/usr/bin/env bash
# Renders Yatty with sample data to build/snapshots/<scene>.png, in a
# throwaway config and zmx directory that never touch the real ones.
# Usage: scripts/snapshot.sh <scene>   Scenes: empty, worktrees, tabs-splits, add-repository,
#   new-worktree-branch, new-worktree-existing, new-worktree-pr, agents, status, pr-panel, merge, diff
set -euo pipefail

scene="${1:?usage: snapshot.sh <scene>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/Yatty.app/Contents/MacOS/Yatty"
out="$root/build/snapshots/$scene.png"
[ -x "$app" ] || { echo "build the app first: make app" >&2; exit 1; }

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
sandbox="$(cd "$sandbox" && pwd -P)"
mkdir -p "$sandbox/config/yatty" "$sandbox/zmx"
printf '{ "agentCommand": "" }\n' > "$sandbox/config/yatty/config.json"

# A sample repository with two worktrees.
repo="$sandbox/repos/sample-app"
git init -q -b main "$repo"
printf '# Sample\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" -c user.name=y -c user.email=y@y commit -q -m init
git -C "$repo" worktree add -q "$repo/.worktrees/login" -b feature/login
git -C "$repo" worktree add -q "$repo/.worktrees/crash-on-start" -b fix/crash-on-start
login="$repo/.worktrees/login"
git -C "$repo" branch -q release/1.0

state="$sandbox/config/yatty/state.json"
case "$scene" in
  empty) ;;
  worktrees)
    cat > "$state" <<EOF
{ "repos": [{ "name": "sample-app", "path": "$repo" }], "selectedWorktree": "$login" }
EOF
    ;;
  tabs-splits)
    cat > "$state" <<EOF
{
  "repos": [{ "name": "sample-app", "path": "$repo" }],
  "selectedWorktree": "$login",
  "layouts": {
    "$login": {
      "selectedTab": "t1",
      "tabs": [
        { "id": "t0", "focusedPane": "0", "root": { "pane": { "_0": "0" } } },
        { "id": "t1", "name": "dev server", "focusedPane": "b2", "root": { "split": {
          "_0": "horizontal", "ratio": 0.55,
          "first": { "pane": { "_0": "a1" } },
          "second": { "split": { "_0": "vertical", "ratio": 0.5,
            "first": { "pane": { "_0": "b2" } }, "second": { "pane": { "_0": "c3" } } } } } } }
      ]
    }
  }
}
EOF
    ;;
  add-repository)
    cat > "$state" <<EOF
{ "repos": [{ "name": "sample-app", "path": "$repo" }], "selectedWorktree": "$repo" }
EOF
    cat > "$sandbox/repos.json" <<'EOF'
[{"name":"sample-app","full_name":"me/sample-app","description":"The sample","private":true},
 {"name":"agentree-tui","full_name":"BeerHobbyist/agentree-tui","description":"A terminal workspace for coding agents","private":true},
 {"name":"ghostty","full_name":"ghostty-org/ghostty","description":"Fast, native, feature-rich terminal emulator","private":false},
 {"name":"zmx","full_name":"neurosnap/zmx","description":"Session attach/detach for the terminal","private":false},
 {"name":"a-repository-with-a-very-long-name-that-should-truncate","full_name":"some-organization/a-repository-with-a-very-long-name-that-should-truncate","description":"Long description that goes on and on to check that one line is all a row gets in the picker list","private":false}]
EOF
    export YATTY_SNAPSHOT_SHEET=add-repository YATTY_REPO_FIXTURE="$sandbox/repos.json"
    ;;
  new-worktree-branch|new-worktree-existing|new-worktree-pr)
    cat > "$state" <<EOF
{ "repos": [{ "name": "sample-app", "path": "$repo", "nameWithOwner": "me/sample-app" }], "selectedWorktree": "$repo" }
EOF
    cat > "$sandbox/prs.json" <<'EOF'
[{"number":42,"title":"Login with magic links","headRefName":"feature/magic-links","isCrossRepository":false,"author":{"login":"octo"}},
 {"number":41,"title":"Fix the crash on start","headRefName":"fix/crash-on-start","isCrossRepository":false,"author":{"login":"octo"}},
 {"number":37,"title":"Translate the settings screen into Polish, with a title long enough to need cutting","headRefName":"main","isCrossRepository":true,"author":{"login":"contributor"}}]
EOF
    export YATTY_SNAPSHOT_SHEET="$scene" YATTY_PR_FIXTURE="$sandbox/prs.json"
    ;;
  agents)
    cat > "$state" <<EOF
{ "repos": [{ "name": "sample-app", "path": "$repo" }], "selectedWorktree": "$login" }
EOF
    session() { printf 'yatty-%s' "$(printf '%s' "$1" | shasum -a 256 | cut -c1-10)"; }
    mkdir -p "$sandbox/state/agents"
    now="$(date +%s)"
    echo "needs-action $now" > "$sandbox/state/agents/$(session "$login")"
    echo "working $now" > "$sandbox/state/agents/$(session "$repo/.worktrees/crash-on-start")"
    echo "done $now" > "$sandbox/state/agents/$(session "$repo")"
    ;;
  status|pr-panel|merge)
    cat > "$state" <<EOF
{ "repos": [{ "name": "sample-app", "path": "$repo", "nameWithOwner": "me/sample-app" }], "selectedWorktree": "$login" }
EOF
    printf 'More\nlines\n' >> "$login/README.md"
    touch "$login/new-file.swift"
    cat > "$sandbox/badges.json" <<'EOF'
{ "feature/login": { "number": 42, "title": "Login with magic links", "checks": "pass" },
  "fix/crash-on-start": { "number": 41, "title": "Fix the crash on start", "checks": "fail", "isDraft": true },
  "main": null }
EOF
    export YATTY_BADGE_FIXTURE="$sandbox/badges.json"
    cat > "$sandbox/details.json" <<'EOF'
{"number":42,"title":"Login with magic links","url":"https://github.com/me/sample-app/pull/42","state":"OPEN","isDraft":false,
 "author":{"login":"octo"},"baseRefName":"main","headRefName":"feature/login","headRefOid":"4f2a9c1e","additions":214,"deletions":37,"changedFiles":9,
 "updatedAt":"2026-11-06T10:00:00Z","mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","reviewDecision":"REVIEW_REQUIRED",
 "latestReviews":[{"author":{"login":"reviewer"},"state":"APPROVED","submittedAt":"2026-11-06T09:00:00Z","body":""},
                  {"author":{"login":"lead"},"state":"CHANGES_REQUESTED","submittedAt":"2026-11-06T08:00:00Z","body":"See inline"}],
 "reviewRequests":[{"login":"security-team"}],
 "reviews":[{"author":{"login":"lead"},"state":"CHANGES_REQUESTED","submittedAt":"2026-11-06T08:00:00Z","body":"The token expiry needs a test."}],
 "comments":[{"author":{"login":"octo"},"body":"Ready for another look — **expiry** is now configurable.","createdAt":"2026-11-06T09:30:00Z","url":"https://github.com"}],
 "labels":[{"name":"feature","color":"0e8a16"},{"name":"needs-review","color":"fbca04"}],
 "statusCheckRollup":[{"name":"build","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://github.com"},
                      {"name":"unit tests","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.com"},
                      {"name":"lint","status":"IN_PROGRESS","detailsUrl":"https://github.com"}],
 "body":"Adds **magic link** login.\n\n- emails a one-time link\n- links expire after 15 minutes"}
EOF
    export YATTY_PR_DETAILS_FIXTURE="$sandbox/details.json"
    [ "$scene" = status ] || export YATTY_SNAPSHOT_SHEET="$scene"
    ;;
  diff)
    cat > "$state" <<EOF
{ "repos": [{ "name": "sample-app", "path": "$repo" }], "selectedWorktree": "$login" }
EOF
    for n in 1 2 3; do
      echo "change $n" >> "$login/README.md"
      git -C "$login" -c user.name=y -c user.email=y@y commit -qam "Change number $n to the readme"
    done
    export YATTY_SNAPSHOT_SHEET=diff
    ;;
  *) echo "unknown scene: $scene" >&2; exit 1 ;;
esac

rm -f "$out"
# Window restoration off: snapshots share the real app's bundle id, so they'd
# reopen at whatever size the real window last had.
log="$sandbox/app.log"
XDG_CONFIG_HOME="$sandbox/config" YATTY_STATE_DIR="$sandbox/state" YATTY_ZMX_DIR="$sandbox/zmx" \
  YATTY_SNAPSHOT="$out" YATTY_SNAPSHOT_DELAY="${YATTY_SNAPSHOT_DELAY:-3}" \
  "$app" -ApplePersistenceIgnoreState YES >"$log" 2>&1 || true
grep '^snapshot:' "$log" | sort -u >&2 || true
[ -f "$out" ] || { echo "no snapshot written" >&2; exit 1; }
echo "$out"
