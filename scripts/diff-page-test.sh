#!/usr/bin/env bash
# The diff tab's page (Resources/diff/viewer.html) and the code view's
# (code.html) in jsdom with the bundled libraries, driven as a user would.
# Needs node and npm; jsdom is installed once into a cache outside the repo.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
command -v node >/dev/null && command -v npm >/dev/null || { echo "diff-page-test: needs node and npm" >&2; exit 1; }
cache="${YATTY_JSDOM_CACHE:-${TMPDIR:-/tmp}/yatty-jsdom}"
if [ ! -d "$cache/node_modules/jsdom" ]; then
  mkdir -p "$cache"
  (cd "$cache" && npm init -y >/dev/null && npm install --silent jsdom@24 >/dev/null)
fi
NODE_PATH="$cache/node_modules" node "$root/Tests/diff-page/page-test.js" "$root/Resources/diff"
NODE_PATH="$cache/node_modules" node "$root/Tests/diff-page/code-test.js" "$root/Resources/diff"
