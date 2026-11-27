#!/usr/bin/env bash
# HomeDrive Mac app installer. In Terminal on your Mac, run:
#
#   curl -fsSL https://raw.githubusercontent.com/maxax4253/homedrive/main/install-mac.sh | bash
#
# Downloads the latest built app from GitHub Releases into /Applications.
# If there's no release yet, it builds the app from source instead.
set -euo pipefail

REPO="maxax4253/homedrive"
APP="/Applications/HomeDrive.app"

[ "$(uname -s)" = "Darwin" ] || { echo "Run this on your Mac."; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading the latest HomeDrive..."
if curl -fsSL -o "$tmp/HomeDrive.zip" "https://github.com/$REPO/releases/latest/download/HomeDrive.zip"; then
  ditto -x -k "$tmp/HomeDrive.zip" "$tmp"
  osascript -e 'quit app "HomeDrive"' >/dev/null 2>&1 || true
  rm -rf "$APP"
  mv "$tmp/HomeDrive.app" "$APP"
  # Downloaded with curl, so no quarantine flag, but clear it just in case.
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
  # Register the Finder "Move to HomeDrive" service.
  /System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
  echo "Installed to $APP"
  open "$APP"
else
  echo "No release found, building from source instead (needs: xcode-select --install)."
  git clone --depth 1 "https://github.com/$REPO.git" "$tmp/src"
  "$tmp/src/mac/build-app.sh"
fi
