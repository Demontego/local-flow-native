import AppKit
import Foundation

/// Minimal menubar shell — links liblocal_flow_ffi via bridging header / module.
/// Build: `make macos` (compiles Rust dylib + swiftc).

@main
struct LocalFlowAppMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private let engine = EngineBridge()
    private var overlay: OverlayController!
    private var hotkey: HotkeyMonitor!
    private var audio: AudioCapture?
    private var listening = false
    private var modelsReady = false
    /// Last real app in front (not Control Center / ourselves) — paste target.
    private var lastUserApp: NSRunningApplication?
    /// Set when hold started via LF menubar (focus stolen); nil for Ctrl+Option.
    private var restoreAppAfterPaste: NSRunningApplication?
    private var appActivateObserver: NSObjectProtocol?
    /// Text we actually typed into the field (append-only during hold).
    private var liveCommitted = ""
    private var liveBusy = false
    /// Captured at hold start (before live typing) so cleanup sees real window/field context.
    private var holdContext = DictationCtx()
    /// Char before caret was a word → insert leading space on first paste.
    private var needsLeadingSpace = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        overlay = OverlayController()
        trackFrontmostApps()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.title = "LF"
            btn.toolTip = "Hold left mouse = dictate · Right-click = menu · Or hold Ctrl+Option"
            btn.sendAction(on: [.leftMouseDown, .leftMouseUp, .rightMouseDown])
            btn.target = self
            btn.action = #selector(statusButtonEvent)
        }

        menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Load models", action: #selector(loadModels), keyEquivalent: "l"))
        menu.addItem(NSMenuItem(title: "Download Whisper", action: #selector(downloadWhisper), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Download Qwen3 (1.7B ~1GB)", action: #selector(downloadQwen), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Microphone settings", action: #selector(openMic), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Accessibility settings", action: #selector(openAccessibility), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Fix Accessibility (reset + reopen settings)", action: #selector(fixAccessibility), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Input Monitoring settings", action: #selector(openInputMonitoring), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Retry hotkey / permissions", action: #selector(retryPermissions), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Dump AX context (debug)", action: #selector(dumpContext), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        // Do NOT assign statusItem.menu — left-click is push-to-talk.

        hotkey = HotkeyMonitor(onPress: { [weak self] in self?.holdStart(stoleFocus: false) },
                               onRelease: { [weak self] in self?.holdEnd() })

        overlay.show("Starting…")
        bootstrapPermissionsThenArm()

        DispatchQueue.global().async { [weak self] in
            let s = self?.engine.loadModels() ?? "fail"
            DispatchQueue.main.async {
                self?.modelsReady = s.contains("asr=whisper")
                self?.overlay.show(self?.readyMessage(models: s) ?? s)
            }
        }
    }

    private func trackFrontmostApps() {
        lastUserApp = Self.usableFrontmost()
        appActivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            if Self.isPasteableApp(app) {
                self?.lastUserApp = app
            }
        }
    }

    private static func usableFrontmost() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication, isPasteableApp(app) else {
            return nil
        }
        return app
    }

    private static func isPasteableApp(_ app: NSRunningApplication) -> Bool {
        guard let bid = app.bundleIdentifier else { return false }
        if bid == Bundle.main.bundleIdentifier { return false }
        // Status-item click often activates these — skip as paste targets.
        let skip = [
            "com.apple.controlcenter",
            "com.apple.systemuiserver",
            "com.apple.NotificationCenter",
            "com.apple.loginwindow",
        ]
        return !skip.contains(bid)
    }

    /// Left hold = dictate (works without Input Monitoring). Right-click = menu.
    @objc private func statusButtonEvent() {
        guard let type = NSApp.currentEvent?.type else { return }
        switch type {
        case .leftMouseDown:
            holdStart(stoleFocus: true)
        case .leftMouseUp:
            holdEnd()
        case .rightMouseDown:
            if let btn = statusItem.button {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: btn.bounds.height + 2), in: btn)
            }
        default:
            break
        }
    }

    private func bootstrapPermissionsThenArm() {
        // Hotkey uses flagsState poll — no Input Monitoring. No AX modal on launch.
        _ = hotkey.start()
        Permissions.requestMicrophone { [weak self] micOk in
            DispatchQueue.main.async {
                guard let self else { return }
                if !micOk {
                    self.overlay.show("Allow Microphone for Local Whisper Flow\n(right-click LF → Microphone)")
                } else if !Permissions.isAccessibilityTrusted() {
                    self.overlay.show(
                        "Ready — hold Ctrl+Option (or LF).\nFor auto-paste: enable Accessibility once"
                    )
                }
            }
        }
    }

    private func readyMessage(models: String) -> String {
        if Permissions.micStatus() != .authorized {
            return "Need Microphone permission"
        }
        if !models.contains("asr=whisper") {
            return "Whisper not loaded — Download Whisper + Load models\n\(models)"
        }
        let ax = Permissions.isAccessibilityTrusted() ? "AX✓" : "AX✗ fix via menu"
        return "Ready — Ctrl+Option · \(ax)\n\(models)"
    }

    @objc private func retryPermissions() {
        overlay.wake()
        _ = hotkey.rearm()
        if !Permissions.isAccessibilityTrusted() {
            Permissions.openAccessibilitySettings()
        }
        Permissions.requestMicrophone { [weak self] micOk in
            DispatchQueue.main.async {
                guard let self else { return }
                if !micOk {
                    self.overlay.show("Microphone still denied")
                    Permissions.openMicrophoneSettings()
                } else {
                    let ax = Permissions.isAccessibilityTrusted()
                        ? "paste OK"
                        : "enable Accessibility for paste"
                    self.overlay.show("Hotkey armed — hold Ctrl+Option\n\(ax)")
                }
            }
        }
    }

    @objc private func loadModels() {
        DispatchQueue.global().async { [weak self] in
            let s = self?.engine.loadModels() ?? "fail"
            DispatchQueue.main.async {
                self?.modelsReady = s.contains("asr=whisper")
                self?.overlay.show("Loaded: \(s)")
            }
        }
    }

    @objc private func downloadWhisper() {
        runDownload(title: "Whisper") { engine, ctx in
            engine.downloadWhisper(progress: ctx)
        }
    }

    @objc private func downloadQwen() {
        runDownload(title: "Qwen3") { engine, ctx in
            engine.downloadQwen(progress: ctx)
        }
    }

    private func runDownload(
        title: String,
        work: @escaping (EngineBridge, DownloadProgressCtx) -> String
    ) {
        overlay.wake()
        overlay.showProgress(title: title, percent: 0)
        let ctx = DownloadProgressCtx()
        ctx.overlay = overlay
        ctx.title = title
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let wire = work(self.engine, ctx)
            DispatchQueue.main.async {
                self.overlay.hideProgress()
                if wire.hasPrefix("error") {
                    self.overlay.show("\(title) failed: \(wire)")
                } else if wire.hasPrefix("already:") {
                    let path = String(wire.dropFirst("already:".count))
                    self.overlay.show("\(title) already downloaded\n\(path)")
                } else {
                    self.overlay.show("\(title) ready — Load models\n\(wire)")
                }
            }
        }
    }

    @objc private func openMic() { Permissions.openMicrophoneSettings() }
    @objc private func openAccessibility() { Permissions.openAccessibilitySettings() }
    @objc private func openInputMonitoring() { Permissions.openInputMonitoringSettings() }

    /// ggml Metal aborts in atexit (`ggml_metal_rsets_free`) if we tear down normally.
    /// Process is exiting anyway — skip C++ static destructors.
    @objc private func quitApp() {
        Darwin._exit(0)
    }

    /// Stale Accessibility toggles after rebuild: reset TCC for our bundle, then user re-adds app.
    @objc private func fixAccessibility() {
        overlay.wake()
        overlay.show("Resetting Accessibility for this app…")
        let bid = Bundle.main.bundleIdentifier ?? "ai.localflow.native"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", bid]
        try? task.run()
        task.waitUntilExit()
        Permissions.openAccessibilitySettings()
        overlay.show(
            "In Accessibility:\n1) remove Local Whisper Flow (−)\n2) add via + → /Applications\n3) enable · relaunch app"
        )
    }

    @objc private func dumpContext() {
        let ctx = ContextCollector.gather()
        let summary = """
        \(ctx.appName) (\(ctx.bundleId))
        channel: \(ctx.channelHint)
        draft: \(ctx.beforeText.prefix(80))
        messages: \(ctx.chatLines.count)
        \(ctx.chatLines.suffix(6).joined(separator: "\n"))
        """
        overlay.show(summary)
        NSLog("LocalFlow dump:\n%@", summary)
    }

    private func holdStart(stoleFocus: Bool) {
        guard !listening else { return }
        if !modelsReady {
            overlay.show("Models still loading / Whisper missing")
            return
        }
        if Permissions.micStatus() != .authorized {
            overlay.show("Microphone denied — open settings")
            Permissions.openMicrophoneSettings()
            return
        }
        // Ctrl+Option: keep focus in the target field — do not activate() later.
        // LF icon: remember app to restore after menubar click stole focus.
        restoreAppAfterPaste = stoleFocus ? (Self.usableFrontmost() ?? lastUserApp) : nil
        liveCommitted = ""
        liveBusy = false
        needsLeadingSpace = ContextCollector.cursorNeedsLeadingSpace()
        holdContext = ContextCollector.gather()
        listening = true
        overlay.wake()
        if !engine.startHold() {
            listening = false
            overlay.show("Busy — try again")
            return
        }
        let capture = AudioCapture { [weak self] samples in
            self?.engine.pushAudio(samples)
        }
        audio = capture
        if !capture.start() {
            listening = false
            engine.cancelHold()
            audio = nil
            overlay.show("Mic failed — check Microphone permission")
            return
        }
        overlay.show("Listening…")
        NSLog("LocalFlow: Listening started")
        // Live: append-only into field. Final: cleanup edit replaces committed span.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while self?.listening == true {
                Thread.sleep(forTimeInterval: 0.65)
                guard let self, self.listening else { continue }
                let partial = self.engine.partialTranscript()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !partial.isEmpty else { continue }
                DispatchQueue.main.sync {
                    guard self.listening, !self.liveBusy else { return }
                    self.liveBusy = true
                    let result = Pasteboard.liveAppend(
                        committed: self.liveCommitted,
                        hypothesis: partial,
                        needsLeadingSpace: self.needsLeadingSpace,
                        restoreApp: self.restoreAppAfterPaste
                    )
                    self.liveCommitted = result.committed
                    self.overlay.show(result.hypothesis.isEmpty ? "Listening…" : result.hypothesis)
                    self.liveBusy = false
                }
            }
        }
    }

    private func holdEnd() {
        guard listening else { return }
        listening = false
        audio?.stop()
        audio = nil
        overlay.show("Editing…")
        NSLog("LocalFlow: final + cleanup")
        // Prefer hold-start context (window/app/draft before we typed into the field).
        var ctx = holdContext
        if ctx.appName.isEmpty || ctx.channelHint.isEmpty {
            let again = ContextCollector.gather()
            if ctx.appName.isEmpty { ctx.appName = again.appName }
            if ctx.bundleId.isEmpty { ctx.bundleId = again.bundleId }
            if ctx.channelHint.isEmpty { ctx.channelHint = again.channelHint }
            if ctx.chatLines.isEmpty { ctx.chatLines = again.chatLines }
        }
        let leading = needsLeadingSpace
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            for _ in 0..<40 where self.liveBusy {
                Thread.sleep(forTimeInterval: 0.05)
            }
            let committed: String = DispatchQueue.main.sync { self.liveCommitted }
            let result = self.engine.endHold(ctx: ctx)
            let raw = result.raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let clean = result.clean.trimmingCharacters(in: .whitespacesAndNewlines)
            var final = clean.isEmpty ? raw : clean
            if final.hasPrefix("error:") || final.hasPrefix("empty:") {
                DispatchQueue.main.async {
                    self.liveCommitted = ""
                    self.restoreAppAfterPaste = nil
                    self.needsLeadingSpace = false
                    self.overlay.show(final)
                }
                return
            }
            if final.isEmpty { final = committed }
            let restore = self.restoreAppAfterPaste

            let out = Pasteboard.commitFinal(
                replacing: committed,
                with: final,
                needsLeadingSpace: leading,
                restoreApp: restore
            ) { [weak self] in
                self?.overlay.hideForPaste()
            }
            DispatchQueue.main.async {
                self.liveCommitted = ""
                self.restoreAppAfterPaste = nil
                self.needsLeadingSpace = false
                self.overlay.wake()
                if final.isEmpty {
                    self.overlay.show("No speech — hold longer")
                } else if out.result == .copied && !out.axTrusted {
                    self.overlay.show("Copied — Cmd+V\nFix Accessibility")
                } else {
                    self.overlay.show(final)
                }
            }
        }
    }
}
