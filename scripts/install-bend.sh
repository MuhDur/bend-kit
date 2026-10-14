#!/usr/bin/env bash
# Install the pinned Bend for CI (linux-x64). Optional prefix, else ~/.bend.
# Bump VER and SHA together.
set -euo pipefail
VER=2.0.37
SHA=84c32465a39bc9ac315eade23f470cb8db03153dc860f89564fcfec153c3e445
dest=${1:-$HOME/.bend}
name="bend-$VER-linux-x64.tar.gz"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp/$name" \
  "https://github.com/bendlang/bend/releases/download/v$VER/$name"
echo "$SHA  $tmp/$name" | sha256sum -c -
tar -xzf "$tmp/$name" -C "$tmp"
mkdir -p "$dest/bin"
rm -rf "$dest/bend2" "$dest/guide"
mv "$tmp/bend/bend2" "$tmp/bend/guide" "$dest/"
mv -f "$tmp/bend/bin/bend" "$dest/bin/bend"
"$dest/bin/bend" version
