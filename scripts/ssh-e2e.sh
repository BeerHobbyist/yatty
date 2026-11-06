#!/usr/bin/env bash
# SSH projects against a real sshd on 127.0.0.1, run as you with its own
# keys, config and zmx directory; your ~/.ssh and your Yatty are untouched.
# The "remote" user is you, with your login shell. Opens a Yatty window for
# part of the run. Usage: ssh-e2e.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# Short: ControlPath sockets and zmx's live under it.
tmp="/private/tmp/yatty-ssh-e2e-$(id -u)"
rm -rf "$tmp"
mkdir -p "$tmp/home/we ird 'dir'" "$tmp/bin" "$tmp/rzmx" "$tmp/config/yatty" "$tmp/state"
mkdir -m 700 "$tmp/ctl"
ln -s "$root/Vendor/zmx" "$tmp/bin/zmx"

fail() { echo "FAIL: $*" >&2; exit 1; }

# The server: keys, a port, and a session environment that finds this zmx
# and keeps its sessions apart.
ssh-keygen -q -t ed25519 -N '' -f "$tmp/hostkey"
ssh-keygen -q -t ed25519 -N '' -f "$tmp/id"
ssh-keygen -q -t ed25519 -N 'pass phrase' -f "$tmp/id_pp"
cat "$tmp/id.pub" "$tmp/id_pp.pub" >"$tmp/authorized_keys"
port=$((23000 + RANDOM % 2000))
cat >"$tmp/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $tmp/hostkey
AuthorizedKeysFile $tmp/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PidFile $tmp/sshd.pid
SetEnv PATH=$tmp/bin:/usr/bin:/bin ZMX_DIR=$tmp/rzmx
EOF
/usr/sbin/sshd -f "$tmp/sshd_config" -E "$tmp/sshd.log"

app_pid=
cleanup() {
  [ -n "$app_pid" ] && kill "$app_pid" 2>/dev/null || true
  # Every shared connection to the test server: the tests' and the app's.
  pkill -f "ssh: $tmp/" 2>/dev/null || true
  for s in $(ZMX_DIR="$tmp/rzmx" "$tmp/bin/zmx" list --short 2>/dev/null); do
    ZMX_DIR="$tmp/rzmx" "$tmp/bin/zmx" kill "$s" >/dev/null 2>&1 || true
  done
  if [ -f "$tmp/sshd.pid" ]; then
    # The server's connections, then the server.
    pkill -P "$(cat "$tmp/sshd.pid")" 2>/dev/null || true
    kill "$(cat "$tmp/sshd.pid")" 2>/dev/null || true
  fi
  # Clients of sessions that just ended.
  pkill -f "$tmp/bin/zmx" 2>/dev/null || true
}
trap cleanup EXIT

# The client: its own config and known hosts, behind an `ssh` Yatty is told to use.
# Two names for the server, as two different hosts: ssh shares a connection
# per resolved host, port and user (%C), so they mustn't resolve the same.
cat >"$tmp/ssh_config" <<EOF
Host e2e e2e-pp
  AddressFamily inet
  Port $port
  User $(id -un)
  IdentitiesOnly yes
  UserKnownHostsFile $tmp/known_hosts
  StrictHostKeyChecking accept-new
Host e2e
  HostName 127.0.0.1
  IdentityFile $tmp/id
Host e2e-pp
  HostName localhost
  IdentityFile $tmp/id_pp
EOF
printf '#!/bin/sh\nexec /usr/bin/ssh -F %s "$@"\n' "$tmp/ssh_config" >"$tmp/ssh"
chmod +x "$tmp/ssh"
for _ in $(seq 1 20); do "$tmp/ssh" -o BatchMode=yes e2e true 2>/dev/null && break; sleep 0.25; done
"$tmp/ssh" -o BatchMode=yes e2e true 2>/dev/null || fail "the test sshd never answered"

# 1. The helpers against it: probing, a passphrase through askpass, one login.
out="$(cd "$root" && YATTY_SSH_E2E="$tmp" swift test --scratch-path .build/swift --disable-sandbox \
  --filter RealSSHTests 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g')"
grep -q "Test run with 2 tests.* passed" <<<"$out" || { echo "$out" | grep -E '✘|recorded|Test run' >&2; fail "real-ssh tests"; }

# 2. The app: a remote directory's terminal runs there, in zmx there.
app="$tmp/Yatty.app"
YATTY_APP="$app" "$root/scripts/bundle-app.sh" debug >/dev/null 2>&1
dir="$tmp/home/we ird 'dir'"
id="ssh:e2e:$dir"
json_dir="$(printf '%s' "$dir" | sed 's/"/\\"/g')"
cat >"$tmp/config/yatty/state.json" <<EOF
{ "selectedWorktree": "ssh:e2e:$json_dir",
  "hosts": [{ "host": "e2e", "home": "$tmp/home", "zmx": "$tmp/bin/zmx", "needsPassword": false,
              "directories": ["$json_dir"] }] }
EOF
printf '{ "agentCommand": "" }\n' >"$tmp/config/yatty/config.json"
# Named after the host and the directory (Worktree.sessionKey).
session="yatty-$(printf '%s' "$id" | shasum -a 256 | cut -c1-10)"
rzmx() { ZMX_DIR="$tmp/rzmx" "$tmp/bin/zmx" "$@"; }
launch() {
  XDG_CONFIG_HOME="$tmp/config" YATTY_STATE_DIR="$tmp/state" YATTY_ZMX_DIR="$tmp/zmx" YATTY_SSH="$tmp/ssh" \
    "$app/Contents/MacOS/Yatty" -ApplePersistenceIgnoreState YES >>"$tmp/app.log" 2>&1 &
  app_pid=$!
}
shows() { for _ in $(seq 1 40); do rzmx history "$session" 2>/dev/null | grep -qF -- "$1" && return 0; sleep 0.25; done; return 1; }

launch
for _ in $(seq 1 40); do rzmx list --short 2>/dev/null | grep -qx "$session" && break; sleep 0.25; done
rzmx list --short | grep -qx "$session" || fail "the remote session never started"
sleep 1
rzmx send "$session" $'pwd\r'
shows "$dir" || fail "the remote shell didn't start in the directory"

# 3. The connection drops: the session stays, and so does the pane.
for child in $(pgrep -P "$(cat "$tmp/sshd.pid")"); do kill "$child"; done
sleep 2
kill -0 "$app_pid" 2>/dev/null || fail "the app died with the connection"
rzmx list --short | grep -qx "$session" || fail "a dropped connection ended the remote session"
grep -q '"tabs":\[\]' "$tmp/config/yatty/state.json" && fail "a dropped connection closed the pane"
rzmx send "$session" $'echo while""-away\r'

# 4. Quit and relaunch: the pane reattaches to the same session.
kill "$app_pid"; wait "$app_pid" 2>/dev/null || true
launch
sleep 4
[ "$(rzmx list --short | grep -c "^yatty-")" = 1 ] || fail "relaunching made another session"
rzmx send "$session" $'echo back""-again\r'
shows "back-again" || fail "the reattached session doesn't run"
shows "while-away" || fail "the session lost what happened while it was away"
echo "ssh e2e: ok"
