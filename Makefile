.PHONY: build test ffi ffi-macos ffi-ios ffi-ios-sim ffi-android ffi-android-arm64 \
	ffi-android-armv7 ffi-android-x64 ffi-windows ffi-linux macos dmg windows full clean \
	sign-identity clean-install-macos flutter-analyze package-android-jni package-ios-libs \
	android-debug android-aab ios-simulator ios-archive
SIGN_IDENTITY ?=

CARGO ?= $(HOME)/.cargo/bin/cargo
FLUTTER ?= flutter
# Honor sandbox/CI CARGO_TARGET_DIR when set
TARGET_DIR ?= $(or $(CARGO_TARGET_DIR),target)
JNI_LIBS := apps/local_flow_app/android/app/src/main/jniLibs
IOS_LIBS := apps/local_flow_app/ios/NativeLibs
LIB := $(TARGET_DIR)/release/liblocal_flow_ffi.dylib
APP_NAME := Local Whisper Flow
APP_BUNDLE := dist/$(APP_NAME).app
MAC_BIN := LocalFlowNative
MAC_OUT := $(APP_BUNDLE)/Contents/MacOS/$(MAC_BIN)
SWIFT_SRCS := $(wildcard apps/macos/Sources/LocalFlow/*.swift)
HEADER := apps/macos/Sources/LocalFlow/Bridging-Header.h

build:
	$(CARGO) build -p local-flow-core -p local-flow-ffi -p local-flow-windows

test:
	$(CARGO) test -p local-flow-core
	$(CARGO) run -p local-flow-windows

full:
	$(CARGO) build -p local-flow-ffi --release --features full

ffi:
	$(CARGO) build -p local-flow-ffi --release --features full

# Run `rustup target add <target>` before these commands. iOS commands require Xcode.
ffi-macos:
	$(CARGO) build -p local-flow-ffi --release --features full --target aarch64-apple-darwin

ffi-ios:
	SDKROOT="$$(xcrun --sdk iphoneos --show-sdk-path)" $(CARGO) build -p local-flow-ffi --release --features full --target aarch64-apple-ios

ffi-ios-sim:
	SDKROOT="$$(xcrun --sdk iphonesimulator --show-sdk-path)" $(CARGO) build -p local-flow-ffi --release --features full --target aarch64-apple-ios-sim

# Set ANDROID_NDK_HOME. Override ANDROID_NDK_HOST_TAG when the NDK host differs.
ANDROID_NDK_HOST_TAG ?=
# $(1)=rust target  $(2)=ANDROID_ABI
define ANDROID_FFI
	test -n "$$ANDROID_NDK_HOME"
	TAG="$(ANDROID_NDK_HOST_TAG)"; \
	if [ -z "$$TAG" ]; then TAG=$$(ls "$$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" | head -1); fi; \
	rm -rf "$(TARGET_DIR)/$(1)/release/build/whisper-rs-sys-"* "$(TARGET_DIR)/$(1)/release/build/llama-cpp-sys-2-"*; \
	PATH="$$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$$TAG/bin:$$PATH" \
	ANDROID_NDK="$$ANDROID_NDK_HOME" \
	ANDROID_NDK_ROOT="$$ANDROID_NDK_HOME" \
	ANDROID_ABI="$(2)" \
	ANDROID_PLATFORM=android-24 \
	CMAKE_TOOLCHAIN_FILE="$$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
	$(CARGO) build -p local-flow-ffi --release --features full --target $(1)
endef

ffi-android: ffi-android-arm64 ffi-android-armv7 ffi-android-x64

ffi-android-arm64:
	$(call ANDROID_FFI,aarch64-linux-android,arm64-v8a)

ffi-android-armv7:
	$(call ANDROID_FFI,armv7-linux-androideabi,armeabi-v7a)

ffi-android-x64:
	$(call ANDROID_FFI,x86_64-linux-android,x86_64)

# Copy Rust cdylib into Flutter jniLibs (not committed; rebuild before APK/AAB).
package-android-jni: ffi-android-arm64
	mkdir -p "$(JNI_LIBS)/arm64-v8a"
	cp "$(TARGET_DIR)/aarch64-linux-android/release/liblocal_flow_ffi.so" "$(JNI_LIBS)/arm64-v8a/"
	@echo "Packaged $(JNI_LIBS)/arm64-v8a/liblocal_flow_ffi.so"

# llama-cpp-sys builds libcpp-httplib.a but rustc staticlib omits it — ship both.
package-ios-libs: ffi-ios-sim
	mkdir -p "$(IOS_LIBS)"
	cp "$(TARGET_DIR)/aarch64-apple-ios-sim/release/liblocal_flow_ffi.a" "$(IOS_LIBS)/"
	HTTPLIB=$$(find "$(TARGET_DIR)/aarch64-apple-ios-sim/release/build" -path '*/cpp-httplib/libcpp-httplib.a' | head -1); \
	test -n "$$HTTPLIB"; \
	cp "$$HTTPLIB" "$(IOS_LIBS)/libcpp-httplib.a"
	cp apps/macos/Sources/LocalFlow/local_flow_c_api.h "$(IOS_LIBS)/"
	@echo "Packaged $(IOS_LIBS)/liblocal_flow_ffi.a + libcpp-httplib.a"

# Run on Windows with the MSVC toolchain installed.
ffi-windows:
	$(CARGO) build -p local-flow-ffi --release --features full,vulkan --target x86_64-pc-windows-msvc

# Run on Ubuntu 24.04 with build-essential installed.
ffi-linux:
	$(CARGO) build -p local-flow-ffi --release --features full,vulkan --target x86_64-unknown-linux-gnu

macos: ffi
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	mkdir -p "$(APP_BUNDLE)/Contents/Frameworks"
	mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	cp apps/macos/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	cp apps/macos/Resources/AppIcon.icns "$(APP_BUNDLE)/Contents/Resources/"
	cp apps/macos/Resources/StatusIcon.png "$(APP_BUNDLE)/Contents/Resources/"
	cp apps/macos/Resources/StatusIcon@2x.png "$(APP_BUNDLE)/Contents/Resources/"
	cp "$(LIB)" "$(APP_BUNDLE)/Contents/Frameworks/"
	swiftc -O -parse-as-library \
		-import-objc-header $(HEADER) \
		-I apps/macos/Sources/LocalFlow \
		$(SWIFT_SRCS) \
		-L "$(APP_BUNDLE)/Contents/Frameworks" \
		-llocal_flow_ffi \
		-framework AppKit -framework AVFoundation -framework ApplicationServices -framework Carbon -framework CoreGraphics \
		-o "$(MAC_OUT)"
	@OLD=$$(otool -L "$(MAC_OUT)" | awk '/liblocal_flow_ffi/{print $$1; exit}'); \
		if [ -n "$$OLD" ]; then install_name_tool -change "$$OLD" @executable_path/../Frameworks/liblocal_flow_ffi.dylib "$(MAC_OUT)"; fi
	install_name_tool -id @rpath/liblocal_flow_ffi.dylib "$(APP_BUNDLE)/Contents/Frameworks/liblocal_flow_ffi.dylib"
	# Prefer persistent identity (scripts/ensure_signing_identity.sh). Ad-hoc (-s -)
	# changes hash every build → Accessibility re-prompted every launch.
	@IDENT="$(SIGN_IDENTITY)"; \
	if [ -z "$$IDENT" ]; then \
	  IDENT=$$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Local Whisper Flow Dev\)"/\1/p' | head -1); \
	fi; \
	if [ -n "$$IDENT" ]; then \
	  echo "codesign with: $$IDENT"; \
	  codesign --force --deep --sign "$$IDENT" \
	    --identifier "ai.localflow.native" \
	    --entitlements apps/macos/LocalWhisperFlow.entitlements \
	    "$(APP_BUNDLE)"; \
	else \
	  echo "codesign ad-hoc (run: bash scripts/ensure_signing_identity.sh for stable TCC)"; \
	  codesign --force --deep --sign - \
	    --identifier "ai.localflow.native" \
	    --entitlements apps/macos/LocalWhisperFlow.entitlements \
	    "$(APP_BUNDLE)"; \
	fi
	xattr -cr "$(APP_BUNDLE)" || true
	@echo "Built $(MAC_OUT)"

sign-identity:
	bash scripts/ensure_signing_identity.sh

dmg: macos
	bash scripts/build_dmg.sh

clean-install-macos:
	bash scripts/clean_install_macos.sh

windows:
	$(CARGO) build -p local-flow-windows --release --features full,vulkan
	@ls -la "$(TARGET_DIR)/release/local-flow-windows"* 2>/dev/null || true
	@echo "Windows tray binary under $(TARGET_DIR)/release/"

flutter-analyze:
	cd apps/local_flow_app && $(FLUTTER) pub get && $(FLUTTER) analyze && $(FLUTTER) test

android-debug: package-android-jni
	cd apps/local_flow_app && $(FLUTTER) pub get && $(FLUTTER) build apk --debug
	bash scripts/write_artifact_metadata.sh apps/local_flow_app/build/app/outputs/flutter-apk/app-debug.apk dist/android

# Required secrets: ANDROID_KEYSTORE_PATH, ANDROID_KEYSTORE_PASSWORD,
# ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD.
android-aab: package-android-jni
	test -n "$$ANDROID_KEYSTORE_PATH" -a -n "$$ANDROID_KEYSTORE_PASSWORD" -a -n "$$ANDROID_KEY_ALIAS" -a -n "$$ANDROID_KEY_PASSWORD"
	cd apps/local_flow_app && $(FLUTTER) pub get && $(FLUTTER) build appbundle --release
	bash scripts/write_artifact_metadata.sh apps/local_flow_app/build/app/outputs/bundle/release/app-release.aab dist/android

ios-simulator: package-ios-libs
	cd apps/local_flow_app && $(FLUTTER) pub get && $(FLUTTER) build ios --simulator --no-codesign

# Required: Apple signing identity/profile configured in Keychain and
# IOS_EXPORT_OPTIONS_PLIST pointing to an App Store export-options plist.
ios-archive:
	test -n "$$IOS_EXPORT_OPTIONS_PLIST"
	cd apps/local_flow_app && $(FLUTTER) pub get && $(FLUTTER) build ipa --release --export-options-plist "$$IOS_EXPORT_OPTIONS_PLIST"
	bash scripts/write_artifact_metadata.sh apps/local_flow_app/build/ios/ipa/*.ipa dist/ios

clean:
	$(CARGO) clean
	rm -rf dist
