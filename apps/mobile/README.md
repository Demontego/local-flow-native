# Mobile shells (Phase 3)

Shared engine: `local-flow-ffi` via UniFFI.

## Reality

iOS/Android **cannot** paste into arbitrary apps like macOS/Windows.
Product surface:

- Custom keyboard extension (record → insert into current field), or
- Companion app (record → copy / share)

## Layout

```
apps/mobile/
  ios/          # Swift package consuming UniFFI generated Swift
  android/      # Kotlin module consuming UniFFI generated Kotlin
```

## Generate bindings

```bash
# from repo root (after cargo build -p local-flow-ffi)
cargo run -p uniffi-bindgen-cli -- generate \
  --library target/debug/liblocal_flow_ffi.dylib \
  --language kotlin --language swift \
  --out-dir apps/mobile/generated
```

See `ios/LocalFlowKeyboard/README.md` and `android/localflow/README.md`.
