#!/usr/bin/env bash
# Idempotent Cloud Agent setup for Local Flow Native.
# Prepares the Rust engine, the native whisper.cpp/llama.cpp build toolchain,
# the Flutter mobile shell, and the Android SDK/NDK so the Kotlin IME + Rust
# JNI + Dart shell can be compiled and verified. Safe to run repeatedly.
#
# Platforms that cannot be built on Linux (macOS/Swift, Windows tray/MSVC, iOS)
# are intentionally out of scope; those need their own toolchains.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

ANDROID_SDK_ROOT=/opt/android-sdk
ANDROID_NDK_VERSION=28.2.13676358
ANDROID_CMDLINE_TOOLS=commandlinetools-linux-16111833_latest.zip

# 1. Rust: workspace deps require the 2024 edition, so a stable toolchain newer
#    than the base image's 1.83 is needed. rustup is preinstalled.
rustup toolchain install stable --profile minimal --no-self-update
rustup default stable
rustup target add aarch64-linux-android

# The Makefile calls $(HOME)/.cargo/bin/cargo; point it at the rustup proxy.
mkdir -p "$HOME/.cargo/bin"
ln -sf "$(command -v cargo)" "$HOME/.cargo/bin/cargo"

# 2. C++ standard-library dev files for the GCC install that clang / cc-rs pick
#    when building the `full` feature (whisper.cpp + llama.cpp). Without this the
#    native link fails with "cannot find -lstdc++". `unzip` is needed below.
if ! dpkg -s libstdc++-14-dev >/dev/null 2>&1 || ! command -v unzip >/dev/null; then
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends libstdc++-14-dev unzip
fi

# 3. Flutter SDK for the mobile shell (apps/local_flow_app).
if [ ! -x /opt/flutter/bin/flutter ]; then
  sudo git clone --depth 1 -b stable https://github.com/flutter/flutter.git /opt/flutter
fi
sudo chown -R "$(id -u):$(id -g)" /opt/flutter
git config --global --add safe.directory /opt/flutter
sudo ln -sf /opt/flutter/bin/flutter /usr/local/bin/flutter
sudo ln -sf /opt/flutter/bin/dart /usr/local/bin/dart
flutter --version

# 4. Android SDK + NDK so `make android-debug` (Kotlin IME + Rust JNI + Dart)
#    can be built and verified. Versions track Flutter's Android defaults.
sudo mkdir -p "$ANDROID_SDK_ROOT"
sudo chown -R "$(id -u):$(id -g)" "$ANDROID_SDK_ROOT"
if [ ! -x "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" ]; then
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/cmdline.zip" \
    "https://dl.google.com/android/repository/$ANDROID_CMDLINE_TOOLS"
  unzip -q "$tmp/cmdline.zip" -d "$tmp"
  mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools/latest"
  cp -r "$tmp/cmdline-tools/"* "$ANDROID_SDK_ROOT/cmdline-tools/latest/"
  rm -rf "$tmp"
fi
sdkmanager="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"
yes | "$sdkmanager" --licenses >/dev/null 2>&1 || true
"$sdkmanager" --install \
  "platform-tools" "platforms;android-36" "build-tools;36.0.0" \
  "ndk;$ANDROID_NDK_VERSION" >/dev/null

export ANDROID_SDK_ROOT
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export ANDROID_NDK_HOME="$ANDROID_SDK_ROOT/ndk/$ANDROID_NDK_VERSION"
flutter config --android-sdk "$ANDROID_SDK_ROOT" >/dev/null 2>&1 || true

# Persist Android env for future login shells and the Makefile android targets.
sudo tee /etc/profile.d/android.sh >/dev/null <<EOF
export ANDROID_SDK_ROOT=$ANDROID_SDK_ROOT
export ANDROID_HOME=$ANDROID_SDK_ROOT
export ANDROID_NDK_HOME=$ANDROID_SDK_ROOT/ndk/$ANDROID_NDK_VERSION
export PATH="$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:\$PATH"
EOF

# 5. Warm the builds. The toolchain above is the hard requirement; the heavy
#    Android warm builds are best-effort so a transient failure can't wedge setup.
cargo build -p local-flow-core -p local-flow-ffi -p local-flow-windows
(cd apps/local_flow_app && flutter pub get)
make package-android-jni CARGO=cargo || echo "warn: Android JNI warm build skipped"
(cd apps/local_flow_app && flutter build apk --debug) || echo "warn: debug APK warm build skipped"

echo "Local Flow Native environment ready."
