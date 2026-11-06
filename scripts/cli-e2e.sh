#!/usr/bin/env bash
# Runs the `yatty` CLI against a real Yatty, apart from the user's: its own
# bundle, config, state, zmx sessions and a throwaway repo. Opens a window for
# the length of the run. Usage: cli-e2e.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# Short: Unix socket paths are limited.
tmp="/private/tmp/yatty-e2e-$(id -u)"
app="$tmp/Yatty.app"
rm -rf "$tmp"
mkdir -p "$tmp/config/yatty" "$tmp/state" "$tmp/zmx"
YATTY_APP="$app" "$root/scripts/bundle-app.sh" debug >/dev/null

export XDG_CONFIG_HOME="$tmp/config" YATTY_STATE_DIR="$tmp/state" YATTY_ZMX_DIR="$tmp/zmx"
zmx() { ZMX_DIR="$tmp/zmx" "$app/Contents/MacOS/zmx" "$@"; }
cli="$app/Contents/Resources/bin/yatty"

repo="$tmp/repo"
git init -q "$repo"
git -C "$repo" -c user.email=e2e@yatty -c user.name=e2e commit -q --allow-empty -m init
echo change >"$repo/file.txt"
repo="$(cd "$repo" && pwd -P)"
cat >"$tmp/config/yatty/state.json" <<EOF
{ "repos": [{ "name": "repo", "path": "$repo" }], "selectedWorktree": "$repo" }
EOF
# No agent; a stand-in sandbox that marks what runs in it.
cat >"$tmp/config/yatty/config.json" <<'EOF'
{ "agentCommand": "", "sandboxCommand": "env YATTY_E2E_SANDBOX=yes" }
EOF

"$app/Contents/MacOS/Yatty" -ApplePersistenceIgnoreState YES >"$tmp/app.log" 2>&1 &
pid=$!
cleanup() {
  kill "$pid" 2>/dev/null || true
  for s in $(zmx list --short 2>/dev/null); do zmx kill "$s" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
y() { YATTY_WORKTREE="$repo" "$cli" "$@"; }
fenced() { FENCE_SANDBOX=1 YATTY_WORKTREE="$repo" "$cli" "$@"; }
# What a command that should fail prints (pipefail would count its failure).
refused() { "$@" 2>&1 && echo "(it succeeded)" || true; }
# Polls `tab read` until it shows the pattern.
shows() {
  for _ in $(seq 1 40); do
    "$@" 2>/dev/null | grep -qF -- "$pattern" && return 0
    sleep 0.25
  done
  return 1
}

for _ in $(seq 1 40); do [ -S "$tmp/state/app.sock" ] && break; sleep 0.25; done
[ -S "$tmp/state/app.sock" ] || fail "the app's socket never appeared"
[ -S "$tmp/state/sandbox.sock" ] || fail "the sandbox socket never appeared"
# The worktrees load after the sockets open.
for _ in $(seq 1 40); do y tab list >/dev/null 2>&1 && break; sleep 0.25; done

[ "$(y tab list | wc -l | tr -d ' ')" = 1 ] || fail "a new worktree should have one tab"

# Commands work in any login shell (fish too). `hello""-42` prints as
# hello-42, so finding that means it ran, not just that it was typed.
# A background tab runs its command at once, and outlives it.
[ "$(y tab new --name dev -- 'echo hello""-42')" = 2 ] || fail "tab new didn't print the new tab's number"
pattern="hello-42"; shows y tab read dev || fail "the background tab's command didn't run"
y tab new --name dev 2>/dev/null && fail "a second tab named dev was made"
y tab list | grep -q $'^1\t.*\t(active)' || fail "tab new took the selection"

y tab send dev 'echo "a  b"""-sent'
pattern="a  b-sent"; shows y tab read dev --lines 5 || fail "tab send didn't type its text"
y tab send dev --no-enter 'sleep 30' --key Enter
sleep 0.5
y tab send dev --key C-c
y tab send dev 'echo after""-interrupt'
pattern="after-interrupt"; shows y tab read dev --lines 5 || fail "C-c didn't stop the sleep"
y tab rename dev web
y tab list | grep -q $'^2\tweb' || fail "rename didn't stick"
y tab select web
y tab list | grep -q $'^2\tweb\t(active)' || fail "select didn't select"

# The sandbox's socket: its own tabs only, and what they run is in the sandbox.
refused fenced tab send web 'echo escaped' | grep -q "types only into tabs opened from one" ||
  fail "a sandboxed agent typed into the user's tab"
fenced tab new --name sb -- 'echo sandbox=$YATTY_E2E_SANDBOX' >/dev/null
pattern="sandbox=yes"; shows fenced tab read sb || fail "the sandboxed tab isn't in the sandbox"
fenced tab send sb 'echo typed""-2'
pattern="typed-2"; shows fenced tab read sb || fail "a sandboxed agent couldn't type into its own tab"
fenced diff | grep -q "^diff (working) opened in" || fail "a sandboxed diff didn't open"
y tab list --json | grep -q '"name":"diff: Working changes","panes":1,"sandboxed":true' ||
  fail "the sandboxed diff tab isn't marked"

y diff staged | grep -q "^diff (staged) opened in" || fail "diff staged didn't open"
y diff --nope 2>/dev/null && fail "a diff ref starting with - was taken"
y status --json | grep -q "\"path\":\"$repo\"" || fail "status doesn't list the worktree"

# Closing: every tab but the last.
while [ "$(y tab list | wc -l | tr -d ' ')" -gt 1 ]; do y tab close 2; done
refused y tab close 1 | grep -q "only tab" || fail "the last tab was closed"

kill "$pid"
wait "$pid" 2>/dev/null || true
started=$(date +%s)
refused y tab list | grep -q "isn't running" || fail "no app, but no 'isn't running'"
[ $(( $(date +%s) - started )) -le 1 ] || fail "no app took too long to report"
echo "cli e2e: ok"
