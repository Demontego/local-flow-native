#!/bin/bash
# Build a classic drag-to-Applications DMG: Local Whisper Flow-0.1.0.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP_NAME="Local Whisper Flow"
APP="$DIST/${APP_NAME}.app"
VERSION="0.1.0"
VOLNAME="Local Whisper Flow"
DMG="$DIST/${APP_NAME}-${VERSION}.dmg"
TMP_DMG="$DIST/.lwf-rw.dmg"
STAGE="$DIST/dmg-stage"

if [[ ! -x "$APP/Contents/MacOS/LocalFlowNative" ]]; then
  echo "Missing app — run make macos first"
  exit 1
fi

# Detach stale volume from a previous failed build
if [[ -d "/Volumes/${VOLNAME}" ]]; then
  hdiutil detach "/Volumes/${VOLNAME}" -quiet || hdiutil detach "/Volumes/${VOLNAME}" -force || true
fi

rm -rf "$STAGE" "$DMG" "$TMP_DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
xattr -cr "$STAGE/${APP_NAME}.app" || true
ln -s /Applications "$STAGE/Applications"

# Writable image so we can set Finder window layout
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -ov \
  -fs HFS+ \
  -format UDRW \
  "$TMP_DMG"

# Mount read-write (path may contain spaces — take everything after /Volumes/)
ATTACH_OUT="$(hdiutil attach -readwrite -noverify -noautoopen "$TMP_DMG")"
MOUNT_DIR="$(printf '%s\n' "$ATTACH_OUT" | grep -o '/Volumes/.*' | tail -1)"
if [[ -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
  echo "Failed to mount $TMP_DMG"
  printf '%s\n' "$ATTACH_OUT"
  exit 1
fi

# Classic installer window: app left, Applications right
osascript <<EOF
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 160, 840, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set position of item "${APP_NAME}.app" of container window to {160, 190}
    set position of item "Applications" of container window to {480, 190}
    update without registering applications
    delay 0.5
    close
    open
    delay 0.5
    close
  end tell
end tell
EOF

sync
hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force

hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f "$TMP_DMG"
rm -rf "$STAGE"

echo "==> dmg: $DMG"
ls -lh "$DMG"
