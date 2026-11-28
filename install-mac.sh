#!/usr/bin/env bash
# Installs HomeDrive on your Mac. In Terminal, run:
#
#   curl -fsSL https://raw.githubusercontent.com/maxax4253/homedrive/main/install-mac.sh | bash
#
# One app for everything: open it and choose "Keep my files on this Mac" (this
# Mac becomes your HomeDrive) or "Connect to my HomeDrive". Running this again
# updates it. Downloads the latest build from GitHub Releases into /Applications
# (if there's no release yet, it builds from source instead).
set -euo pipefail

REPO="maxax4253/homedrive"
APP="/Applications/HomeDrive.app"

[ "$(uname -s)" = "Darwin" ] || { echo "Run this on your Mac."; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The newest Mac app release (tagged v<version>; server releases are server-v*).
url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=30" 2>/dev/null |
  grep -o '"browser_download_url": *"[^"]*"' | sed 's/.*"\(https:[^"]*\)"$/\1/' |
  grep '/download/v[0-9][^/]*/HomeDrive\.zip$' | head -1 || true)

echo "Downloading the latest HomeDrive app..."
if [ -n "$url" ] && curl -fsSL -o "$tmp/HomeDrive.zip" "$url"; then
  ditto -x -k "$tmp/HomeDrive.zip" "$tmp"
  osascript -e 'quit app "HomeDrive"' >/dev/null 2>&1 || true
  # The separate "HomeDrive Server" app (test builds) is now part of HomeDrive:
  # stop and remove it. Its setup, account, pairing and Tailscale are kept and
  # picked up by HomeDrive.
  if [ -d "/Applications/HomeDrive Server.app" ]; then
    pkill -f "HomeDrive Server.app/Contents/MacOS/" 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/HomeDrive Server.app"
    echo "Replaced HomeDrive Server (your setup is kept)"
  fi
  rm -rf "$APP"
  mv "$tmp/HomeDrive.app" "$APP"
  # Downloaded with curl, so no quarantine flag, but clear it just in case.
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
  # Register the Finder "Move to HomeDrive" service.
  /System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
  echo "Installed to $APP"
  [ -n "${NO_OPEN:-}" ] || open "$APP"
else
  echo "No release found, building from source instead (needs: xcode-select --install)."
  git clone --depth 1 "https://github.com/$REPO.git" "$tmp/src"
  "$tmp/src/mac/build-app.sh"
fi
