#!/usr/bin/env bash
# Builds HomeDrive.app and puts it in /Applications.
# Run from anywhere on your Mac:  ~/homedrive/mac/build-app.sh
#
# For release builds (used by GitHub Actions):
#   OUT=dist UNIVERSAL=1 ./build-app.sh   -> dist/HomeDrive.app for Apple silicon + Intel, no install
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Swift isn't installed. Run: xcode-select --install"
  exit 1
fi

ARGS=(-c release)
if [ "${UNIVERSAL:-0}" = "1" ]; then
  ARGS+=(--arch arm64 --arch x86_64)
fi

echo "Building (first build takes a minute)..."
swift build "${ARGS[@]}"
BIN="$(swift build "${ARGS[@]}" --show-bin-path)/HomeDrive"

# Assemble in a temp folder so Spotlight/Launchpad never sees a second copy.
STAGE=$(mktemp -d)
APP="$STAGE/HomeDrive.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HomeDrive"
cp Info.plist "$APP/Contents/Info.plist"
iconutil -c icns AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# The HomeDrive server, hidden inside the app: it keeps the files when this Mac
# is the one that does. Built from ../core with Go (https://go.dev/dl).
if command -v go >/dev/null 2>&1; then
  echo "Building the server part..."
  V=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
  FLAGS=(-trimpath -tags "notray,nowindow" -ldflags "-s -w -X main.Version=$V")
  if [ "${UNIVERSAL:-0}" = "1" ]; then
    (cd ../core && GOARCH=arm64 go build "${FLAGS[@]}" -o "$STAGE/hd-arm64" . \
                && GOARCH=amd64 go build "${FLAGS[@]}" -o "$STAGE/hd-amd64" .)
    lipo -create -output "$APP/Contents/MacOS/homedrive-server" "$STAGE/hd-arm64" "$STAGE/hd-amd64"
    rm -f "$STAGE/hd-arm64" "$STAGE/hd-amd64"
  else
    (cd ../core && go build "${FLAGS[@]}" -o "$APP/Contents/MacOS/homedrive-server" .)
  fi
elif [ "${REQUIRE_SERVER:-0}" = "1" ]; then
  echo "Go is needed to build the server part."
  exit 1
else
  echo "Go isn't installed, so this build can only connect to a HomeDrive (it can't keep files)."
fi

# Ad-hoc sign (free) so macOS is happy running it.
codesign --force --deep --sign - "$APP" >/dev/null

if [ -n "${OUT:-}" ]; then
  mkdir -p "$OUT"
  rm -rf "${OUT:?}/HomeDrive.app"
  mv "$APP" "$OUT/HomeDrive.app"
  rm -rf "$STAGE"
  echo "Built $OUT/HomeDrive.app"
  exit 0
fi

DEST="/Applications/HomeDrive.app"
osascript -e 'quit app "HomeDrive"' >/dev/null 2>&1 || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
rm -rf "$STAGE" build
touch "$DEST"   # nudge Finder/Dock to pick up the new icon
# Register the Finder "Move to HomeDrive" / "Copy to HomeDrive" services.
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
echo "Installed to $DEST"
open "$DEST"
