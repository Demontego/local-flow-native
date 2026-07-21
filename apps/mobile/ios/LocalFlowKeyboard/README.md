# iOS — Local Flow Keyboard (scaffold)

1. Create Xcode Keyboard Extension target `LocalFlowKeyboard`.
2. Link `liblocal_flow_ffi.a` (static) + UniFFI generated Swift from `apps/mobile/generated`.
3. UI: hold-to-talk button → `LocalFlowEngine.startHold` / `pushAudio` / `endHold` → insert text into `textDocumentProxy`.

No system-wide hotkey; Full Access required for network model download (optional — ship models in app bundle).
