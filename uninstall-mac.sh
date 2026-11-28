#!/usr/bin/env bash
# Removes HomeDrive from this Mac: the HomeDrive app, HomeDrive Server, their
# settings and sign-ins, and start-at-login. Your files are NOT deleted: the
# folder HomeDrive Server shared stays where it is, and the offline folders
# go to the Trash. In Terminal, run:
#
#   curl -fsSL https://raw.githubusercontent.com/maxax4253/homedrive/main/uninstall-mac.sh | bash
set -euo pipefail

[ "$(uname -s)" = "Darwin" ] || { echo "Run this on your Mac."; exit 1; }

osascript -e 'quit app "HomeDrive"' >/dev/null 2>&1 || true
pkill -f "HomeDrive Server.app/Contents/MacOS/" 2>/dev/null || true
sleep 1

rm -f "$HOME/Library/LaunchAgents/com.homedrive.server.plist"
rm -rf "/Applications/HomeDrive Server.app" "/Applications/HomeDrive.app"
rm -rf "$HOME/Library/Application Support/HomeDrive Server" "$HOME/Library/Application Support/HomeDrive"
defaults delete com.maxkaplan.homedrive >/dev/null 2>&1 || true

# Offline copies: to the Trash (not deleted), in case anything in them matters.
for d in "$HOME"/"HomeDrive Offline"*; do
  [ -d "$d" ] || continue
  dest="$HOME/.Trash/$(basename "$d") $(date +%H%M%S)"
  mv "$d" "$dest" && echo "Moved $(basename "$d") to the Trash"
done

echo "HomeDrive is removed from this Mac. Your files weren't touched."
echo "If HomeDrive Server was set up with Tailscale, you can also remove the"
echo "\"homedrive\" machine at https://login.tailscale.com/admin/machines"
