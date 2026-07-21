#!/usr/bin/env bash
# Rebuild macOS .icns + status/tray PNGs from assets/icon/icon-1024.png
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/assets/icon/icon-1024.png"
test -f "$SRC"

ICONSET="$ROOT/assets/icon/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET" "$ROOT/apps/macos/Resources" "$ROOT/apps/windows/assets"

make_size() {
  local px="$1" name="$2"
  sips -z "$px" "$px" "$SRC" --out "$ICONSET/$name" >/dev/null
}

make_size 16   icon_16x16.png
make_size 32   icon_16x16@2x.png
make_size 32   icon_32x32.png
make_size 64   icon_32x32@2x.png
make_size 128  icon_128x128.png
make_size 256  icon_128x128@2x.png
make_size 256  icon_256x256.png
make_size 512  icon_256x256@2x.png
make_size 512  icon_512x512.png
make_size 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$ROOT/apps/macos/Resources/AppIcon.icns"
sips -z 32 32 "$SRC" --out "$ROOT/apps/macos/Resources/StatusIcon.png" >/dev/null
sips -z 64 64 "$SRC" --out "$ROOT/apps/macos/Resources/StatusIcon@2x.png" >/dev/null
sips -z 32 32 "$SRC" --out "$ROOT/apps/windows/assets/tray-icon.png" >/dev/null
sips -z 256 256 "$SRC" --out "$ROOT/apps/windows/assets/app-icon.png" >/dev/null
sips -z 16 16 "$SRC" --out "$ROOT/assets/icon/icon-16.png" >/dev/null
sips -z 32 32 "$SRC" --out "$ROOT/assets/icon/icon-32.png" >/dev/null
sips -z 64 64 "$SRC" --out "$ROOT/assets/icon/icon-64.png" >/dev/null
sips -z 128 128 "$SRC" --out "$ROOT/assets/icon/icon-128.png" >/dev/null
sips -z 256 256 "$SRC" --out "$ROOT/assets/icon/icon-256.png" >/dev/null

echo "Wrote apps/macos/Resources/AppIcon.icns + StatusIcon*.png"
echo "Wrote apps/windows/assets/tray-icon.png"
