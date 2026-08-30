# Local Flow Native

On-device dictation: **Rust core** (whisper.cpp + llama.cpp) + thin platform shells.
Audio, models, history, and personalization stay on the device.

| Shell | Path | Status |
|-------|------|--------|
| macOS menubar | `apps/macos` | Tap **fn** toggle, Hub, scratch, AX paste |
| Windows tray | `apps/windows` | Tap **Right Ctrl**, Hub, scratch, clipboard paste |
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
| Windows `*-windows-x64.exe` / `.zip` | Portable tray; tap Right Ctrl (`make windows` / `scripts/build_windows.ps1`) |
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

Run the exe → tray **Local Flow** → **tap Right Ctrl** to start/stop dictate → pastes on stop.
Hold **Ctrl+Alt** still works. Tray: Open Hub / Dictate to Scratch / Learn from clipboard /
Load models / Download Whisper / Download Gemma 4 / Quit.
Data dir: `%LOCALAPPDATA%\Local Flow Native\` (`hub/` for stats, sessions, notes).

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

First launch: grant **Microphone**, **Accessibility**, and **Input Monitoring** (for fn).
If the hotkey does nothing: menubar **LF → Retry hotkey / permissions**.

**Tap fn** (Globe) to start/stop listening → cleaned text pastes on stop.
Hold **Ctrl+Option** or hold the menubar icon still works. Open **Hub** for stats,
history, scratch notes, and dictionary. **Dictate to Scratch** saves a note (no paste).
After paste, if you edit the text, Local Flow can auto-learn a dictionary rule (Undo in bubble).

## Architecture

```
crates/local-flow-core   session FSM, ASR, cleanup, hub, learn, history
crates/local-flow-ffi    C ABI (+ JNI for Android; UniFFI stubs optional)
apps/macos               Swift menubar / fn tap / Hub / AX paste
apps/windows             Rust tray / Right Ctrl / Hub / clipboard paste
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

- **Whisper:** `ggml-base-ru.bin` (~141 MB, Russian fine-tune)
- **Gemma 4 E2B:** `gemma-4-E2B-it-Q4_K_M.gguf` (~3.2 GB cleanup)
- Then **Load models**. Without the LLM, cleanup falls back to a small heuristic.
- Context comes from Accessibility / IME — no screenshot path.

## Personalization + Hub

Local-only (no account, no sync):

- **Hub** (all shells): words today/week, streak, session history, scratch notes, dictionary
  - macOS menubar window · Windows tray Hub window · Flutter app Hub tabs
- Dictionary replacements (manual or learned from post-paste edits) and voice snippets
- Per-app writing style, polish selection, live typing, context capture, cleanup toggles
- Spoken punctuation (e.g. **запятая**, **точка**, **новая строка**)
- Undo / retry last paste (short window, focus must still match)

Files under the app data directory: `personalization.json`, `hub/stats.json`,
`hub/sessions.jsonl`, `hub/notes.json`.

## Quality checks

```bash
cargo test -p local-flow-core --test heuristic -- --skip qwen_cleanup
make macos
make flutter-analyze
```

Before a release, manually verify dictation and paste in a few real apps
(editor, messenger, browser, native text field).

Store signing notes (credentials never in git): [docs/store/mobile-release.md](docs/store/mobile-release.md).
