# Android — Local Flow IME (scaffold)

1. Android Library / IME service module `localflow`.
2. Depend on UniFFI-generated Kotlin + `liblocal_flow_ffi.so` per ABI.
3. `InputMethodService` with hold mic → PCM 16 kHz → `LocalFlowEngine` → `commitText`.

Permissions: `RECORD_AUDIO`. Models in app files dir (`~/.cache` equivalent).
