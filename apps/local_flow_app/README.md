# Local Flow (Flutter)

Host app for Android IME and iOS keyboard extension. Shares `local-flow-ffi`
with the macOS Swift menubar.

```bash
# from repo root
make flutter-analyze
ANDROID_NDK_HOME=/path/to/ndk make android-debug
make ios-simulator
```

Platform channel: `ai.localflow/native` (application data directory, IME settings).
Store release notes: `../../docs/store/mobile-release.md`.
