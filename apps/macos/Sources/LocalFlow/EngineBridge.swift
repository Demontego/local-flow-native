import Foundation

/// Holds overlay + title for C progress trampoline (must outlive download call).
final class DownloadProgressCtx {
    weak var overlay: OverlayController?
    var title: String = ""
}

final class EngineBridge {
    private let handle: OpaquePointer

    init() {
        handle = lf_engine_new()
    }

    deinit {
        lf_engine_free(handle)
    }

    func loadModels() -> String {
        guard let c = lf_engine_load_models(handle) else { return "error" }
        defer { lf_string_free(c) }
        return String(cString: c)
    }

    func downloadWhisper(progress: DownloadProgressCtx) -> String {
        download(progress: progress, title: "Whisper", fn: lf_engine_download_whisper)
    }

    func downloadQwen(progress: DownloadProgressCtx) -> String {
        download(progress: progress, title: "Qwen", fn: lf_engine_download_qwen)
    }

    private func download(
        progress: DownloadProgressCtx,
        title: String,
        fn: @escaping @convention(c) (
            OpaquePointer?,
            (@convention(c) (UInt32, UnsafeMutableRawPointer?) -> Void)?,
            UnsafeMutableRawPointer?
        ) -> UnsafeMutablePointer<CChar>?
    ) -> String {
        progress.title = title
        let ud = Unmanaged.passUnretained(progress).toOpaque()
        let cb: @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Void = { pct, userdata in
            guard let userdata else { return }
            let ctx = Unmanaged<DownloadProgressCtx>.fromOpaque(userdata).takeUnretainedValue()
            let t = ctx.title
            ctx.overlay?.showProgress(title: t, percent: Int(pct))
        }
        guard let c = fn(handle, cb, ud) else { return "error" }
        defer { lf_string_free(c) }
        return String(cString: c)
    }

    @discardableResult
    func startHold() -> Bool {
        lf_engine_start_hold(handle) == 0
    }

    func cancelHold() {
        lf_engine_cancel_hold(handle)
    }

    func pushAudio(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { buf in
            _ = lf_engine_push_audio(handle, buf.baseAddress, Int32(buf.count))
        }
    }

    func partialTranscript() -> String {
        guard let c = lf_engine_partial(handle) else { return "" }
        defer { lf_string_free(c) }
        return String(cString: c)
    }

    func endHold(ctx: DictationCtx) -> (raw: String, clean: String) {
        let cCtx = ctx.toC()
        defer { lf_context_free(cCtx) }
        guard let res = lf_engine_end_hold(handle, cCtx) else {
            return ("", "")
        }
        defer { lf_session_result_free(res) }
        let raw = res.pointee.raw.map { String(cString: $0) } ?? ""
        let clean = res.pointee.clean.map { String(cString: $0) } ?? ""
        return (raw, clean)
    }
}

struct DictationCtx {
    var appName = ""
    var bundleId = ""
    var channelHint = ""
    var beforeText = ""
    var selectedText = ""
    var chatLines: [String] = []
    var recent: [String] = []
    var screenshotPath: String?

    func toC() -> UnsafeMutablePointer<LFContext> {
        lf_context_new(
            appName,
            bundleId,
            channelHint,
            beforeText,
            selectedText,
            chatLines.joined(separator: "\n"),
            recent.joined(separator: "\n"),
            screenshotPath
        )
    }
}
