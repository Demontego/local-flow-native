# Local Flow Native

On-device dictation: **Rust core** (whisper.cpp + llama.cpp) + thin platform shells.
Audio, models, history, and personalization stay on the device.

| Shell | Path | Status |
|-------|------|--------|
| macOS menubar | `apps/macos` | Hotkey, overlay, Accessibility paste |
| Windows tray | `apps/windows` | Ctrl+Alt hold, tray menu, clipboard paste |
| Flutter + IME | `apps/local_flow_app` | Android IME + iOS keyboard |

License: [MIT](LICENSE). Third-party notices: [THIRD_PARTY.md](THIRD_PARTY.md).

## GitHub Releases

Push a version tag; CI builds packages and attaches them to the Release:

```bash
git tag v0.1.0
git push origin v0.1.0
```

| Asset | Notes |
|-------|--------|
| macOS `.dmg` | Ad-hoc signed menubar app (`make dmg`) |
| Windows `*-windows-x64.exe` / `.zip` | Portable tray; hold Ctrl+Alt (`make windows` / `scripts/build_windows.ps1`) |
| Android `*-android-debug.apk` | Debug build with arm64 JNI |

Store-signed Play/App Store builds are not automated — see
[docs/store/mobile-release.md](docs/store/mobile-release.md).
Manual CI package smoke: Actions → **Mobile package (manual)**.

## Build

```bash
# Rust toolchain on PATH (or: source "$HOME/.cargo/env")
make build
make test
make macos          # → dist/Local Whisper Flow.app
make dmg            # → dist/Local Whisper Flow-0.1.0.dmg
make windows        # → target/release/local-flow-windows.exe (build on Windows)
```

**Windows (PowerShell):**

```powershell
.\scripts\bootstrap_windows.ps1   # once: Rust MSVC + CMake + VS Build Tools
.\scripts\build_windows.ps1       # → dist/release/*-windows-x64.exe + .zip
```

Run the exe → tray tooltip **Local Flow** → hold **Ctrl+Alt** to dictate → release pastes.
Tray menu: Load models / Download Whisper / Download Qwen / Quit.
Data dir: `%LOCALAPPDATA%\Local Flow Native\`.

Mobile (needs Flutter; Android also needs `ANDROID_NDK_HOME`):

```bash
make flutter-analyze
ANDROID_NDK_HOME=/path/to/ndk make android-debug
make ios-simulator
```

Cross-compile FFI:

```bash
rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim \
  aarch64-linux-android armv7-linux-androideabi x86_64-linux-android \
  x86_64-pc-windows-msvc x86_64-unknown-linux-gnu
make ffi-macos
make ffi-ios
make ffi-ios-sim
ANDROID_NDK_HOME=/path/to/ndk make ffi-android
make ffi-windows   # on Windows + MSVC
make ffi-linux     # on Ubuntu 24.04
```

Android NDK linker names live in `.cargo/config.toml` (API 24). Override
`ANDROID_NDK_HOST_TAG` if the NDK host folder is not auto-detected.

## Install (macOS)

Open the DMG → drag **Local Whisper Flow** into **Applications**.

First launch: grant **Microphone**, **Accessibility**, and **Input Monitoring**.
If the hotkey does nothing: menubar **LF → Retry hotkey / permissions**.

Hold **Ctrl+Option** → speak → release → cleaned text is pasted.

## Architecture

```
crates/local-flow-core   session FSM, ASR, cleanup, history
crates/local-flow-ffi    C ABI (+ JNI for Android; UniFFI stubs optional)
apps/macos               Swift menubar / permissions / audio / AX paste
apps/windows             Rust tray / Ctrl+Alt / mic / clipboard paste
apps/local_flow_app      Flutter host + Android IME + iOS keyboard
vendor/whisper-rs-sys    patched whisper.cpp bindgen for mobile NDK
```

Each shell passes its own application-data directory into the C ABI. The core
never reads `HOME` or a shared global cache for models or personalization.

## Models

Weights are not in the DMG/APK (multi-GB). Download from the app after install.

| Platform | Data directory |
|----------|----------------|
| macOS menubar | `~/Library/Application Support/Local Flow Native/` |
| Flutter iOS | App Group `group.ai.localflow.app` |
| Flutter Android | app `filesDir` |
| Windows tray | `%LOCALAPPDATA%\Local Flow Native\` |

- **Whisper:** `ggml-small.bin`
- **Qwen3:** `Qwen3-1.7B-Q4_K_M.gguf` (~1.1 GB cleanup)
- Then **Load models**. Without Qwen, cleanup falls back to a small heuristic.
- Context comes from Accessibility / IME — no screenshot path.

## Personalization (macOS menubar)

Local-only controls in the LF menu:

- Dictionary replacements and voice snippets
- Per-app writing style
- Polish selected text, live typing, context capture, cleanup toggles
- Spoken punctuation (e.g. **запятая**, **точка**, **новая строка**)
- Undo / retry last paste (short window, focus must still match)

Stored under the app data directory as `personalization.json` — no account, no sync.

## Quality checks

```bash
cargo test -p local-flow-core --test heuristic -- --skip qwen_cleanup
make macos
make flutter-analyze
```

Before a release, manually verify dictation and paste in a few real apps
(editor, messenger, browser, native text field).

Store signing notes (credentials never in git): [docs/store/mobile-release.md](docs/store/mobile-release.md).
