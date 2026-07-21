.PHONY: build test ffi macos dmg windows full clean sign-identity clean-install-macos
SIGN_IDENTITY ?=

CARGO ?= $(HOME)/.cargo/bin/cargo
# Honor sandbox/CI CARGO_TARGET_DIR when set
TARGET_DIR ?= $(or $(CARGO_TARGET_DIR),target)
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

macos: ffi
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	mkdir -p "$(APP_BUNDLE)/Contents/Frameworks"
	cp apps/macos/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
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
	$(CARGO) build -p local-flow-windows --release

clean:
	$(CARGO) clean
	rm -rf dist
