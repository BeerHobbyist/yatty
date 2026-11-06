#!/usr/bin/env bash
# Renders Yatty with sample data to build/snapshots/<scene>.png, in a
# throwaway config and zmx directory that never touch the real ones.
# Usage: scripts/snapshot.sh <scene>   Scenes: empty, worktrees, tabs-splits
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
git -C "$repo" -c user.name=y -c user.email=y@y commit -q --allow-empty -m init
git -C "$repo" worktree add -q "$repo/.worktrees/login" -b feature/login
git -C "$repo" worktree add -q "$repo/.worktrees/crash-on-start" -b fix/crash-on-start
login="$repo/.worktrees/login"

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
  *) echo "unknown scene: $scene" >&2; exit 1 ;;
esac

rm -f "$out"
log="$sandbox/app.log"
XDG_CONFIG_HOME="$sandbox/config" YATTY_ZMX_DIR="$sandbox/zmx" \
  YATTY_SNAPSHOT="$out" YATTY_SNAPSHOT_DELAY="${YATTY_SNAPSHOT_DELAY:-3}" \
  "$app" >"$log" 2>&1 || true
[ -f "$out" ] || { grep '^snapshot:' "$log" >&2; echo "no snapshot written" >&2; exit 1; }
echo "$out"
