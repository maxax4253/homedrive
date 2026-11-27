#!/usr/bin/env bash
# Builds HomeDrive.app and puts it in /Applications.
# Run from the mac/ folder on your Mac:  ./build-app.sh
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Swift isn't installed. Run: xcode-select --install"
  exit 1
fi

echo "Building (first build takes a minute)..."
swift build -c release

# Assemble in a temp folder so Spotlight/Launchpad never sees a second copy.
STAGE=$(mktemp -d)
APP="$STAGE/HomeDrive.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/HomeDrive" "$APP/Contents/MacOS/HomeDrive"
cp Info.plist "$APP/Contents/Info.plist"

# Ad-hoc sign so macOS is happy running it locally.
codesign --force --deep --sign - "$APP" >/dev/null

DEST="/Applications/HomeDrive.app"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
rm -rf "$STAGE" build
echo "Installed to $DEST"
open "$DEST"
