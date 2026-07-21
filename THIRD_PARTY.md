# Third-party notices

Local Flow Native links or vendors the following components. Their licenses
apply in addition to this repository's MIT license.

## whisper.cpp (via vendored whisper-rs-sys)

- Path: `vendor/whisper-rs-sys/whisper.cpp`
- License: MIT (see `vendor/whisper-rs-sys/whisper.cpp/LICENSE`)
- Upstream: https://github.com/ggerganov/whisper.cpp
- Note: tree is slimmed (CPU/Metal/BLAS only). See `vendor/README.md`.

## whisper-rs / whisper-rs-sys

- Path: `vendor/whisper-rs-sys` (patched crates.io `whisper-rs-sys`)
- License: Unlicense (upstream crate)
- Why vendored: Android NDK builds must not pick up host macOS BLAS; see
  `Cargo.toml` `[patch.crates-io]` and `vendor/whisper-rs-sys/build.rs`.

## llama.cpp (via llama-cpp-2)

- Crate dependency: `llama-cpp-2` / `llama-cpp-sys-2`
- License: MIT (llama.cpp)

## Flutter / Dart SDK

- Used by `apps/local_flow_app`
- License: BSD-style (Flutter SDK)

Model weights (Whisper GGUF/ggml, Qwen GGUF) are **not** shipped in this
repository. Users download them at runtime into the host app's data directory.
