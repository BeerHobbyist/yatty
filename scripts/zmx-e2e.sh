#!/usr/bin/env bash
# Checks what Yatty assumes of zmx, on a session of its own: `send` types one
# argument exactly as given (flags, quotes and all), `history` shows it, and
# both fail fast for a session that isn't there. Usage: zmx-e2e.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
zmx="$root/Vendor/zmx"
# Short and fixed: Unix socket paths are limited, and a sandbox running this
# has to be told the exact path to allow.
export ZMX_DIR="/private/tmp/yatty-test-$(id -u)/zmx"
export ZMX_NO_DETACH_KEY=1
# A shell that echoes what it was typed the same way everywhere.
export SHELL=/bin/bash
session=e2e
mkdir -p "$ZMX_DIR"
trap '"$zmx" kill "$session" >/dev/null 2>&1 || true' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

"$zmx" kill "$session" >/dev/null 2>&1 || true
"$zmx" run "$session" -d true >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do "$zmx" list --short | grep -qx "$session" && break; sleep 0.3; done
"$zmx" list --short | grep -qx "$session" || fail "session didn't start"

# What `yatty tab send e2e 'echo "a  b" -- --force'` sends: text, then Enter.
"$zmx" send "$session" $'echo "a  b" -- --force \'q\'\r'
sleep 1
"$zmx" history "$session" | grep -q -- "a  b -- --force 'q'" || fail "send didn't type its argument as given"

start=$(date +%s)
if "$zmx" history nosuch-session >/dev/null 2>&1; then fail "history of a missing session succeeded"; fi
if "$zmx" send nosuch-session x >/dev/null 2>&1; then fail "send to a missing session succeeded"; fi
[ $(( $(date +%s) - start )) -le 2 ] || fail "a missing session took too long to fail"
echo "zmx e2e: ok"
