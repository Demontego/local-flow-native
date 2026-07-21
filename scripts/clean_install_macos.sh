#!/bin/bash
# Clean reinstall Local Whisper Flow on macOS (app + TCC + optional DMG rebuild).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Local Whisper Flow"
BUNDLE_ID="ai.localflow.native"
APP="/Applications/${APP_NAME}.app"

echo "==> Quit running app"
pkill -f "${APP}/Contents/MacOS/LocalFlowNative" 2>/dev/null || true
pkill -f "LocalFlowNative" 2>/dev/null || true
sleep 0.4

echo "==> Remove installed app + dist copies"
rm -rf "${APP}"
rm -rf "${ROOT}/dist/${APP_NAME}.app"
rm -rf "${ROOT}/dist/LocalFlowNative.app"
rm -f "${ROOT}/dist/${APP_NAME}-"*.dmg
rm -f "${ROOT}/dist/LocalFlowNative-"*.dmg

echo "==> Reset TCC (Accessibility / Microphone / Listen Event)"
tccutil reset Accessibility "${BUNDLE_ID}" 2>/dev/null || true
tccutil reset Microphone "${BUNDLE_ID}" 2>/dev/null || true
tccutil reset ListenEvent "${BUNDLE_ID}" 2>/dev/null || true
tccutil reset AppleEvents "${BUNDLE_ID}" 2>/dev/null || true

echo "==> Clear paste debug log"
rm -f "${HOME}/.cache/local-flow-native/paste.log"

echo "==> Build"
source "${HOME}/.cargo/env" 2>/dev/null || true
make -C "${ROOT}" dmg

DMG="${ROOT}/dist/${APP_NAME}-0.1.0.dmg"
echo "==> Install from DMG → Applications"
if [[ -f "${DMG}" ]]; then
  MNT="$(mktemp -d)"
  hdiutil attach "${DMG}" -nobrowse -quiet -mountpoint "${MNT}"
  rm -rf "${APP}"
  cp -R "${MNT}/${APP_NAME}.app" /Applications/
  hdiutil detach "${MNT}" -quiet || hdiutil detach "${MNT}" -force
  rmdir "${MNT}" 2>/dev/null || true
else
  cp -R "${ROOT}/dist/${APP_NAME}.app" /Applications/
fi
xattr -cr "${APP}" || true

echo "==> Launch"
open "${APP}"

cat <<EOF

Done. Clean install at:
  ${APP}
  DMG: ${DMG}

NOW (required once):
  1. System Settings → Privacy → Accessibility
  2. Remove any old «Local Whisper Flow» (−)
  3. + → choose ${APP} → enable
  4. Privacy → Microphone → enable Local Whisper Flow
  5. Privacy → Automation → allow System Events if asked
  6. Click a text field → hold Ctrl+Option and speak

Overlay should show AX✓. If paste fails, check:
  ~/.cache/local-flow-native/paste.log
EOF
