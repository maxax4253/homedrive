#!/usr/bin/env bash
# Sets up this Mac as your HomeDrive: installs HomeDrive Server (keeps your files
# and lives in the menu bar) and the HomeDrive app. In Terminal, run:
#
#   curl -fsSL https://raw.githubusercontent.com/maxax4253/homedrive/main/install-server-mac.sh | bash
#
# Then follow the setup page that opens. Running it again updates both apps.
set -euo pipefail

REPO="maxax4253/homedrive"
SERVER="/Applications/HomeDrive Server.app"

[ "$(uname -s)" = "Darwin" ] || { echo "Run this on your Mac."; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Newest server build (test builds count until there's a final release).
echo "Finding the newest HomeDrive Server..."
urls=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=30" |
  grep -o '"browser_download_url": *"[^"]*"' | sed 's/.*"\(https:[^"]*\)"$/\1/')
zip_url=$(printf '%s\n' "$urls" | grep '/download/server-v[^/]*/HomeDrive-Server-mac\.zip$' | head -1)
[ -n "$zip_url" ] || { echo "Couldn't find a HomeDrive Server download. Check your internet connection."; exit 1; }
version=$(printf '%s' "$zip_url" | sed 's#.*/download/server-v\([^/]*\)/.*#\1#')

echo "Downloading HomeDrive Server $version..."
curl -fsSL -o "$tmp/server.zip" "$zip_url"
curl -fsSL -o "$tmp/SHA256SUMS" "${zip_url%/*}/SHA256SUMS"
want=$(grep ' HomeDrive-Server-mac\.zip$' "$tmp/SHA256SUMS" | cut -d' ' -f1)
got=$(shasum -a 256 "$tmp/server.zip" | cut -d' ' -f1)
[ -n "$want" ] && [ "$want" = "$got" ] || { echo "The download doesn't match its fingerprint, so nothing was installed."; exit 1; }

ditto -x -k "$tmp/server.zip" "$tmp/server"
pkill -f "$SERVER/Contents/MacOS/" 2>/dev/null && sleep 1 || true
rm -rf "$SERVER"
mv "$tmp/server/HomeDrive Server.app" "$SERVER"
xattr -dr com.apple.quarantine "$SERVER" 2>/dev/null || true
echo "Installed $SERVER"

# The HomeDrive app, to use your files on this Mac.
curl -fsSL "https://raw.githubusercontent.com/$REPO/main/install-mac.sh" | NO_OPEN=1 bash

open "$SERVER"
echo
echo "Done. Follow the setup page that just opened in your browser."
echo "(It's also in the menu bar: the drive icon near the clock, then Open HomeDrive.)"
