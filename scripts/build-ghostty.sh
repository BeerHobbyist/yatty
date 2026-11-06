#!/usr/bin/env bash
# Builds GhosttyKit.xcframework and Ghostty's runtime resources (shell
# integration, terminfo, themes) from the pinned ThirdParty/ghostty submodule
# into Vendor/. Skips the build when the submodule's commit hasn't changed;
# FORCE=1 rebuilds anyway.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/ThirdParty/ghostty"
out="$root/Vendor"
rev="$(git -C "$src" rev-parse HEAD)"

if [ "${FORCE:-}" != "1" ] && [ -d "$out/GhosttyKit.xcframework" ] &&
  [ "$(cat "$out/.ghostty-rev" 2>/dev/null)" = "$rev" ]; then
  exit 0
fi

command -v zig >/dev/null || { echo "zig not found: brew install zig" >&2; exit 1; }

cd "$src"
ZIG_GLOBAL_CACHE_DIR="$root/.build/zig-global-cache" zig build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=true \
  -Dxcframework-target=native \
  -Demit-macos-app=false \
  --prefix "$out/ghostty" \
  --cache-dir "$root/.build/zig-cache"

rm -rf "$out/GhosttyKit.xcframework"
cp -R "$src/macos/GhosttyKit.xcframework" "$out/GhosttyKit.xcframework"
echo "$rev" > "$out/.ghostty-rev"
