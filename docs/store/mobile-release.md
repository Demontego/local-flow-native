# Mobile store release

Targets: Google Play and Apple App Store. No signing credential, provisioning
profile, key, API token, or keystore belongs in this repository.

Unsigned / debug CI packages (macOS DMG, Windows tray, Android debug APK, iOS
simulator `.app` zip) upload automatically on every merge to `main` via the
**Build all platforms** workflow (`.github/workflows/build-all.yml`). Tag
`v*` builds still publish a GitHub Release from `release.yml`.

## Google Play

Set these protected CI secrets or local environment variables:

- `ANDROID_KEYSTORE_BASE64` in CI (decode it to `ANDROID_KEYSTORE_PATH` locally)
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Run `make android-aab`. Upload the resulting `.aab` first to Play Internal
Testing. Before production rollout, complete Data Safety:

- microphone audio is processed on-device for dictation;
- Qwen3, Whisper, history, diagnostics, and personalization remain on-device;
- the app does not sell, share, or transmit user data;
- the IME is enabled explicitly by the user in Android settings.

## Apple App Store

Create App IDs `ai.localflow.app` and `ai.localflow.app.keyboard`, enable App
Groups, and register `group.ai.localflow.app` for both. Keep App Store Connect
API credentials, signing certificate, and provisioning profiles in protected CI
storage. CI decodes `IOS_EXPORT_OPTIONS_PLIST_BASE64` into
`IOS_EXPORT_OPTIONS_PLIST`; then run `make ios-archive`.

Host app downloads models into the App Group. Keyboard extension reads those
local files and does not download models; it must not request open access for
that path. Complete App Privacy with no tracking and no collected data.

## Manual gates

For every release, install the artifact on a physical device and verify:

1. onboarding and microphone permission wording;
2. model download, restart, and recovery after deleting models;
3. IME/keyboard enablement and final text commit;
4. Qwen cleanup guard and one final insertion;
5. App Group model/settings access on iOS;
6. no network requests during ordinary dictation.
