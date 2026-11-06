#!/usr/bin/env bash
# Downloads the pinned zmx release binary (session persistence) into Vendor/zmx.
set -euo pipefail

version="0.8.1"
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/Vendor"
dest="$out/zmx"

if [ -x "$dest" ] && [ "$(cat "$out/.zmx-version" 2>/dev/null)" = "$version" ]; then
  exit 0
fi

case "$(uname -m)" in
  arm64) arch="aarch64" ;;
  x86_64) arch="x86_64" ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

name="zmx-${version}-macos-${arch}.tar.gz"
url="https://github.com/neurosnap/zmx/releases/download/v${version}/${name}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/$name" "$url"
curl -fsSL -o "$tmp/$name.sha256" "$url.sha256"
(cd "$tmp" && shasum -a 256 -c <(awk -v f="$name" '{print $1"  "f}' "$name.sha256"))

tar -xzf "$tmp/$name" -C "$tmp"
mkdir -p "$out"
install -m 755 "$(find "$tmp" -type f -name zmx -perm -u+x | head -1)" "$dest"
echo "$version" > "$out/.zmx-version"
