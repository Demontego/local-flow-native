import Foundation

/// Thin Swift wrapper around the Rust C ABI for the keyboard extension.
final class KeyboardEngine {
    private var handle: OpaquePointer?

    init?(dataDirectory: String) {
        handle = dataDirectory.withCString { lf_engine_new($0) }
        guard handle != nil else { return nil }
    }

    deinit {
        if let handle {
            lf_engine_free(handle)
        }
    }

    @discardableResult
    func loadModels() -> String {
        guard let handle, let c = lf_engine_load_models(handle) else { return "error" }
        defer { lf_string_free(c) }
        return String(cString: c)
    }

    func startHold() -> Bool {
        guard let handle else { return false }
        return lf_engine_start_hold(handle) == 0
    }

    func cancelHold() {
        guard let handle else { return }
        lf_engine_cancel_hold(handle)
    }

    func pushAudio(_ samples: [Float]) {
        guard let handle else { return }
        samples.withUnsafeBufferPointer { buf in
            _ = lf_engine_push_audio(handle, buf.baseAddress, Int32(buf.count))
        }
    }

    func partial() -> String {
        guard let handle, let c = lf_engine_partial(handle) else { return "" }
        defer { lf_string_free(c) }
        return String(cString: c)
    }

    func endHold(beforeText: String) -> String {
        guard let handle else { return "" }
        let ctx = lf_context_new(
            "iOS Keyboard",
            "ai.localflow.app.keyboard",
            "",
            beforeText,
            "",
            "",
            "",
            nil
        )
        defer { lf_context_free(ctx) }
        guard let result = lf_engine_end_hold(handle, ctx) else { return "" }
        defer { lf_session_result_free(result) }
        return result.pointee.clean.map { String(cString: $0) } ?? ""
    }
}
