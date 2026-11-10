#!/usr/bin/env bash
# Assembles build/Yatty.app (or $YATTY_APP) from the SwiftPM binary,
# Info.plist, Ghostty's resources and zmx, then signs it ad hoc.
# Usage: bundle-app.sh [debug|release]
set -euo pipefail

config="${1:-debug}"
root="$(cd "$(dirname "$0")/.." && pwd)"
app="${YATTY_APP:-$root/build/Yatty.app}"
# Built here too: --show-bin-path only says where, and a stale binary would
# be bundled without a word.
(cd "$root" && swift build -c "$config" --scratch-path .build/swift --disable-sandbox >/dev/null)
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
# The diff window's page and its renderer (diff2html; see THIRD-PARTY.md).
cp -R "$root/Resources/diff" "$app/Contents/Resources/diff"
# The icon, from Resources/AppIcon.icon (open it in Icon Composer to edit):
# Assets.car for macOS 26's Liquid Glass, AppIcon.icns for the rest. Paths
# are absolute, as actool's helper runs elsewhere; it reports on stdout.
scratch="$(mktemp -d)"
log="$(xcrun actool "$root/Resources/AppIcon.icon" --compile "$(cd "$app/Contents/Resources" && pwd)" \
  --app-icon AppIcon --platform macosx --target-device mac --minimum-deployment-target 26.0 \
  --output-partial-info-plist "$scratch/icon.plist")" || { echo "$log" >&2; exit 1; }
rm -rf "$scratch"

codesign --force --sign - "$app/Contents/MacOS/zmx"
codesign --force --sign - "$app/Contents/Resources/bin/yatty"
codesign --force --sign - "$app"
