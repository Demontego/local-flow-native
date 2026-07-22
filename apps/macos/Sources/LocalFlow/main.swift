import AppKit
import Foundation

/// Minimal menubar shell — links liblocal_flow_ffi via bridging header / module.
/// Build: `make macos` (compiles Rust dylib + swiftc).

@main
struct LocalFlowAppMain {
    // NSApplication keeps its delegate weakly; retain it for the whole process.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
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
    private var permissionPollTimer: Timer?
    /// Text we actually typed into the field (append-only during hold).
    private var liveCommitted = ""
    private var liveBusy = false
    /// Captured at hold start (before live typing) so cleanup sees real window/field context.
    private var holdContext = DictationCtx()
    /// Char before caret was a word → insert leading space on first paste.
    private var needsLeadingSpace = false
    private var liveTypingEnabled: Bool {
        UserDefaults.standard.object(forKey: "liveTypingEnabled") as? Bool ?? true
    }
    private var contextCaptureEnabled: Bool {
        UserDefaults.standard.object(forKey: "contextCaptureEnabled") as? Bool ?? true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Catch AppKit terminate→exit paths that bypass quitApp/_exit.
        lf_install_clean_die()
        overlay = OverlayController()
        trackFrontmostApps()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            if let icon = Self.statusBarImage() {
                btn.image = icon
                btn.imagePosition = .imageOnly
            } else {
                btn.title = "LF"
            }
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
        menu.addItem(NSMenuItem(title: "Add dictionary replacement…", action: #selector(addDictionaryRule), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Add voice snippet…", action: #selector(addSnippet), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Set writing style for focused app…", action: #selector(setWritingStyle), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Toggle cleanup", action: #selector(toggleCleanup), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Command: polish selected text", action: #selector(polishSelectedText), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Personalization summary", action: #selector(showPersonalization), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Recent dictation for focused app", action: #selector(showRecentDictation), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Toggle live typing", action: #selector(toggleLiveTyping), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Toggle app context capture", action: #selector(toggleContextCapture), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Undo last Local Flow paste", action: #selector(undoLastPaste), keyEquivalent: "z"))
        menu.addItem(NSMenuItem(title: "Retry last Local Flow paste", action: #selector(retryLastPaste), keyEquivalent: ""))
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
                if Permissions.onboardingStep() == .ready {
                    self?.overlay.show(self?.readyMessage(models: s) ?? s)
                } else {
                    self?.refreshPermissionOnboarding()
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Cmd+Q / Apple events bypass menu Quit. Never return into AppKit
        // terminate→exit→ggml Metal atexit abort.
        lf_die_clean() // noreturn (_exit)
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        lf_die_clean()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshPermissionOnboarding()
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
            if app.bundleIdentifier == Bundle.main.bundleIdentifier {
                self?.refreshPermissionOnboarding()
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
        // Hotkey uses flagsState poll — no Input Monitoring permission required.
        _ = hotkey.start()
        refreshPermissionOnboarding(requestMicrophoneIfNeeded: true)
    }

    private func refreshPermissionOnboarding(requestMicrophoneIfNeeded: Bool = false) {
        let step = Permissions.onboardingStep()
        if step == .ready {
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
            overlay.show(
                modelsReady
                    ? "Ready — Ctrl+Option or LF"
                    : "Permissions ready — loading models…"
            )
            return
        }
        if step == .requestMicrophone, requestMicrophoneIfNeeded {
            Permissions.perform(step) { [weak self] in
                self?.refreshPermissionOnboarding()
            }
            return
        }
        guard let actionTitle = step.actionTitle else { return }
        overlay.showPermission(message: step.message, actionTitle: actionTitle) { [weak self] in
            guard let self else { return }
            Permissions.perform(step) {
                self.refreshPermissionOnboarding()
            }
            self.startPermissionPolling()
        }
    }

    private func startPermissionPolling() {
        guard permissionPollTimer == nil else { return }
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in self?.refreshPermissionOnboarding()
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
        refreshPermissionOnboarding(requestMicrophoneIfNeeded: true)
    }

    @objc private func loadModels() {
        DispatchQueue.global().async { [weak self] in
            let s = self?.engine.loadModels() ?? "fail"
            DispatchQueue.main.async {
                self?.modelsReady = s.contains("asr=whisper")
                if Permissions.onboardingStep() == .ready {
                    self?.overlay.show("Loaded: \(s)")
                } else {
                    self?.refreshPermissionOnboarding()
                }
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

    @objc private func addDictionaryRule() {
        if let result = PersonalizationEditor.addDictionaryRule(engine: engine) {
            overlay.show(result == "ok" ? "Dictionary replacement saved" : result)
        }
    }

    @objc private func addSnippet() {
        if let result = PersonalizationEditor.addSnippet(engine: engine) {
            overlay.show(result == "ok" ? "Voice snippet saved" : result)
        }
    }

    @objc private func setWritingStyle() {
        if let result = PersonalizationEditor.setStyle(
            engine: engine,
            app: Self.usableFrontmost() ?? lastUserApp
        ) {
            overlay.show(result == "ok" ? "Writing style saved" : result)
        }
    }

    @objc private func toggleCleanup() {
        let result = PersonalizationEditor.toggleCleanup(engine: engine)
        overlay.show(result == "ok" ? PersonalizationEditor.summary(engine: engine) : result)
    }

    @objc private func showPersonalization() {
        overlay.show(PersonalizationEditor.summary(engine: engine))
    }

    @objc private func showRecentDictation() {
        guard let bundleID = (Self.usableFrontmost() ?? lastUserApp)?.bundleIdentifier else {
            overlay.show("Focus an app first")
            return
        }
        let recent = engine.recent(for: bundleID)
        overlay.show(recent.isEmpty ? "No recent dictation for this app" : recent.suffix(5).joined(separator: "\n"))
    }

    @objc private func polishSelectedText() {
        let ctx = ContextCollector.gather()
        let selected = ctx.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else {
            overlay.show("Select text first")
            return
        }
        let restore = Self.usableFrontmost() ?? lastUserApp
        overlay.show("Polishing selection…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let output = self.engine.cleanupText(selected, ctx: ctx)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty, !output.hasPrefix("error:") else {
                DispatchQueue.main.async { self.overlay.show(output.isEmpty ? "No result" : output) }
                return
            }
            _ = Pasteboard.commitFinal(
                replacing: "",
                with: output,
                needsLeadingSpace: false,
                restoreApp: restore,
                recordUndo: false
            ) { [weak self] in
                self?.overlay.hideForPaste()
            }
            DispatchQueue.main.async {
                self.overlay.wake()
                self.overlay.show(output)
            }
        }
    }

    @objc private func toggleLiveTyping() {
        let enabled = !liveTypingEnabled
        UserDefaults.standard.set(enabled, forKey: "liveTypingEnabled")
        overlay.show("Live typing: \(enabled ? "on" : "off")")
    }

    @objc private func toggleContextCapture() {
        let enabled = !contextCaptureEnabled
        UserDefaults.standard.set(enabled, forKey: "contextCaptureEnabled")
        overlay.show("App context capture: \(enabled ? "on" : "off")")
    }

    @objc private func undoLastPaste() {
        overlay.show(Pasteboard.undoLastPaste())
    }

    @objc private func retryLastPaste() {
        overlay.show(Pasteboard.retryLastPaste())
    }

    /// ggml Metal aborts in atexit (`ggml_metal_rsets_free`) if we tear down normally.
    /// Process is exiting anyway — skip C++ static destructors.
    @objc private func quitApp() {
        lf_die_clean()
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
        if !contextCaptureEnabled {
            holdContext.beforeText = ""
            holdContext.selectedText = ""
            holdContext.chatLines = []
        }
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
                guard self.liveTypingEnabled, !partial.isEmpty else { continue }
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
        if !contextCaptureEnabled {
            ctx.beforeText = ""
            ctx.selectedText = ""
            ctx.chatLines = []
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
            if final.isEmpty, result.pressEnter {
                Pasteboard.postEnter()
                DispatchQueue.main.async {
                    self.liveCommitted = ""
                    self.restoreAppAfterPaste = nil
                    self.needsLeadingSpace = false
                    self.overlay.wake()
                    self.overlay.show("Pressed Enter")
                }
                return
            }

            let out = Pasteboard.commitFinal(
                replacing: committed,
                with: final,
                needsLeadingSpace: leading,
                restoreApp: restore
            ) { [weak self] in
                self?.overlay.hideForPaste()
            }
            if out.result == .pasted, result.pressEnter {
                Pasteboard.postEnter()
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

    /// Menubar glyph — SF Symbol template so macOS tints like other status items.
    private static func statusBarImage() -> NSImage? {
        let base = NSImage(systemSymbolName: "waveform.and.mic", accessibilityDescription: "Local Flow")
            ?? NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Local Flow")
        guard let base else { return nil }
        let img = base.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        ) ?? base
        img.isTemplate = true
        return img
    }
}
