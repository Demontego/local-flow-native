import Foundation

/// Holds overlay + title for C progress trampoline (must outlive download call).
final class DownloadProgressCtx {
    weak var overlay: OverlayController?
    var title: String = ""
}

final class EngineBridge {
    private let handle: OpaquePointer

    init() {
        let dataDir = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Local Flow Native", isDirectory: true)
        try! FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        guard let handle = dataDir.path.withCString({ lf_engine_new($0) }) else {
            fatalError("Local Flow requires an application data directory")
        }
        self.handle = handle
    }

    deinit {
        lf_engine_free(handle)
    }

    func loadModels() -> String {
        guard let c = lf_engine_load_models(handle) else { return "error" }
        defer { lf_string_free(c) }
        return String(cString: c)
    }

    func personalization() -> PersonalizationSettings {
        guard let c = lf_engine_personalization_json(handle) else { return .default }
        defer { lf_string_free(c) }
        return (try? JSONDecoder().decode(
            PersonalizationSettings.self,
            from: Data(String(cString: c).utf8)
        )) ?? .default
    }

    func savePersonalization(_ settings: PersonalizationSettings) -> String {
        guard let data = try? JSONEncoder().encode(settings),
              let json = String(data: data, encoding: .utf8),
              let c = lf_engine_save_personalization_json(handle, json)
        else { return "error: encode personalization" }
        defer { lf_string_free(c) }
        return String(cString: c)
    }

    func recent(for bundleID: String) -> [String] {
        guard let c = lf_engine_recent_json(handle, bundleID) else { return [] }
        defer { lf_string_free(c) }
        return (try? JSONDecoder().decode([String].self, from: Data(String(cString: c).utf8))) ?? []
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

    func endHold(ctx: DictationCtx) -> (raw: String, clean: String, pressEnter: Bool) {
        let cCtx = ctx.toC()
        defer { lf_context_free(cCtx) }
        guard let res = lf_engine_end_hold(handle, cCtx) else {
            return ("", "", false)
        }
        defer { lf_session_result_free(res) }
        let raw = res.pointee.raw.map { String(cString: $0) } ?? ""
        let clean = res.pointee.clean.map { String(cString: $0) } ?? ""
        return (raw, clean, res.pointee.press_enter != 0)
    }

    func cleanupText(_ text: String, ctx: DictationCtx) -> String {
        let cCtx = ctx.toC()
        defer { lf_context_free(cCtx) }
        guard let c = lf_engine_cleanup_text(handle, text, cCtx) else { return "error: cleanup" }
        defer { lf_string_free(c) }
        return String(cString: c)
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
