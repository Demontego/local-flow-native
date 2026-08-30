#!/usr/bin/env bash
# Idempotent Cloud Agent setup for Local Flow Native.
# Prepares the Rust engine, the native whisper.cpp/llama.cpp build toolchain,
# and the Flutter mobile shell. Safe to run repeatedly.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# 1. Rust: workspace deps require the 2024 edition, so a stable toolchain newer
#    than the base image's 1.83 is needed. rustup is preinstalled.
rustup toolchain install stable --profile minimal --no-self-update
rustup default stable

# The Makefile calls $(HOME)/.cargo/bin/cargo; point it at the rustup proxy.
mkdir -p "$HOME/.cargo/bin"
ln -sf "$(command -v cargo)" "$HOME/.cargo/bin/cargo"

# 2. C++ standard-library dev files for the GCC install that clang / cc-rs pick
#    when building the `full` feature (whisper.cpp + llama.cpp). Without this the
#    native link fails with "cannot find -lstdc++".
if ! dpkg -s libstdc++-14-dev >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends libstdc++-14-dev
fi

# 3. Flutter SDK for the mobile shell (apps/local_flow_app) analyze/test lane.
if [ ! -x /opt/flutter/bin/flutter ]; then
  sudo git clone --depth 1 -b stable https://github.com/flutter/flutter.git /opt/flutter
fi
sudo chown -R "$(id -u):$(id -g)" /opt/flutter
git config --global --add safe.directory /opt/flutter
sudo ln -sf /opt/flutter/bin/flutter /usr/local/bin/flutter
sudo ln -sf /opt/flutter/bin/dart /usr/local/bin/dart
flutter --version

# 4. Warm the Rust workspace (core engine, C ABI, Windows host shell).
cargo build -p local-flow-core -p local-flow-ffi -p local-flow-windows

# 5. Resolve Flutter package dependencies.
(cd apps/local_flow_app && flutter pub get)

echo "Local Flow Native environment ready."
