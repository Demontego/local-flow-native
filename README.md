# Local Flow Native

Cross-platform on-device dictation: **Rust core** (whisper.cpp + llama.cpp) + thin native shells.

| Shell | Path | Status |
|-------|------|--------|
| macOS menubar | `apps/macos` | Phase 1 scaffold (hotkey, overlay, AX, paste) |
| Windows tray | `apps/windows` | Scaffold + engine smoke |
| Mobile IME | `apps/mobile` | UniFFI-oriented stubs |

Python Local Flow (`../local-flow`) remains the daily driver until Mac parity is polished.

## Build

```bash
source ~/.cargo/env
make build
make test
make macos          # → dist/Local Whisper Flow.app
make dmg            # → dist/Local Whisper Flow-0.1.0.dmg (drag to Applications)
make full           # rebuild ffi with whisper.cpp + llama.cpp (slow)
```

Install: open the DMG → drag **Local Whisper Flow** into **Applications**.  
First run: grant **Microphone**, **Accessibility**, and **Input Monitoring** (System Settings → Privacy).  
If the hotkey does nothing after allowing access: menubar **LF → Retry hotkey / permissions**.

## Architecture

```
crates/local-flow-core   session FSM, ASR, cleanup, history
crates/local-flow-ffi    UniFFI + C ABI for shells
apps/macos               Swift UI / permissions / audio
apps/windows             tray shell (Windows target)
apps/mobile              iOS keyboard + Android IME scaffolds
```

## Models

Not inside the `.dmg` (would be multi‑GB). Download from the menubar after install:

Cache: `~/.cache/local-flow-native/models/`

- **Whisper:** menu → Download Whisper (`ggml-small.bin`)
- **Qwen3:** menu → Download Qwen3 (`Qwen3-1.7B-Q4_K_M.gguf` ~1.1 GB, text cleanup)
- Then **Load models**. Without Qwen, cleanup uses a small heuristic.
- Context: Accessibility (AX) from the frontmost app — no vision/screenshot path.

## Hotkey (macOS)

Hold **Ctrl+Option** → speak → release → cleaned text pasted.
