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
# Once its first command has run, the shell reads input: typed earlier, bash
# would throw it away as it starts.
"$zmx" wait "$session" >/dev/null
"$zmx" list --short | grep -qx "$session" || fail "session didn't start"

# What `yatty tab send e2e 'echo "a  b" -- --force'` sends: text, then Enter.
"$zmx" send "$session" $'echo "a  b" -- --force \'q\'\r'
sleep 1
history="$("$zmx" history "$session")"
# The line arrived byte for byte, and the Enter after it ran it.
grep -qF -- "echo \"a  b\" -- --force 'q'" <<<"$history" || fail "send didn't type its argument as given"
grep -qxF -- "a  b -- --force q" <<<"$history" || fail "the Enter after the text didn't run it"

start=$(date +%s)
if "$zmx" history nosuch-session >/dev/null 2>&1; then fail "history of a missing session succeeded"; fi
if "$zmx" send nosuch-session x >/dev/null 2>&1; then fail "send to a missing session succeeded"; fi
[ $(( $(date +%s) - start )) -le 2 ] || fail "a missing session took too long to fail"
echo "zmx e2e: ok"
