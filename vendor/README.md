# Vendored crates

## whisper-rs-sys

Patched crates.io `whisper-rs-sys` so Android NDK builds do not link host
macOS BLAS (see root `Cargo.toml` `[patch.crates-io]` and `build.rs`).

The embedded `whisper.cpp` tree is **slimmed** for Local Flow targets
(macOS Metal, iOS, Android CPU). Unused ggml backends were removed:

CUDA, Vulkan, SYCL, OpenCL, HIP, Hexagon, CANN, MUSA, zDNN, ZenDNN, RPC,
WebGPU, CoreML encoder sources, OpenVINO.

Kept: `ggml-cpu`, `ggml-metal`, `ggml-blas`, plus shared ggml/whisper sources.
Header stubs for removed backends remain under `ggml/include/` because upstream
CMake still lists them in `PUBLIC_HEADERS`.
