#!/usr/bin/env bash
# Assembles build/Yatty.app (or $YATTY_APP) from the SwiftPM binary,
# Info.plist, Ghostty's resources and zmx, then signs it ad hoc.
# Usage: bundle-app.sh [debug|release]
set -euo pipefail

config="${1:-debug}"
root="$(cd "$(dirname "$0")/.." && pwd)"
app="${YATTY_APP:-$root/build/Yatty.app}"
bindir="$(cd "$root" && swift build -c "$config" --scratch-path .build/swift --disable-sandbox --show-bin-path)"
bin="$bindir/Yatty"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$bin" "$app/Contents/MacOS/Yatty"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
# libghostty finds its resources next to the executable, as in Ghostty.app:
# Contents/Resources/ghostty and Contents/Resources/terminfo.
cp -R "$root/Vendor/ghostty/share/ghostty" "$app/Contents/Resources/ghostty"
cp -R "$root/Vendor/ghostty/share/terminfo" "$app/Contents/Resources/terminfo"
install -m 755 "$root/Vendor/zmx" "$app/Contents/MacOS/zmx"
# The `yatty` CLI and its Claude Code skill: Contents/Resources/bin/yatty finds
# the skill at ../skills/yatty/SKILL.md.
mkdir -p "$app/Contents/Resources/bin" "$app/Contents/Resources/skills"
install -m 755 "$bindir/yatty-cli" "$app/Contents/Resources/bin/yatty"
cp -R "$root/skills/yatty" "$app/Contents/Resources/skills/yatty"

codesign --force --sign - "$app/Contents/MacOS/zmx"
codesign --force --sign - "$app/Contents/Resources/bin/yatty"
codesign --force --sign - "$app"
