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
    private var hub: HubWindowController!
    private var hotkey: HotkeyMonitor!
    private var audio: AudioCapture?
    private var listening = false
    private var modelsReady = false
    /// Dictate into Hub scratch (no paste).
    private var scratchMode = false
    /// Last real app in front (not Control Center / ourselves) — paste target.
    private var lastUserApp: NSRunningApplication?
    /// Set when hold started via LF menubar (focus stolen); nil for Ctrl+Option.
    private var restoreAppAfterPaste: NSRunningApplication?
    private var appActivateObserver: NSObjectProtocol?
    private var permissionPollTimer: Timer?
    private var learnPollTimer: Timer?
    /// After paste: watch field edits for auto-dictionary.
    private var lastPasteLearn: (clean: String, raw: String, armedAt: Date, deadline: Date)?
    /// Debounce: only learn after field stops changing.
    private var learnCandidate: String?
    private var learnCandidateSince: Date?
    private var lastLearnedHeard: String?
    /// Progressive Whisper text while holding (overlay). Pasted only after Qwen on release.
    private var transcriptCache = ""
    /// Text typed into the field when live typing is on (append-only during hold).
    private var liveCommitted = ""
    private var liveBusy = false
    /// Captured at hold start (before live typing) so cleanup sees real window/field context.
    private var holdContext = DictationCtx()
    /// Char before caret was a word → insert leading space on first paste.
    private var needsLeadingSpace = false
    private var liveTypingEnabled: Bool {
        // Off by default: hold = Whisper→cache/overlay; release → Qwen → paste → clear.
        // Opt-in: also type into the field while holding.
        UserDefaults.standard.object(forKey: "liveTypingEnabled") as? Bool ?? false
    }
    private var contextCaptureEnabled: Bool {
        UserDefaults.standard.object(forKey: "contextCaptureEnabled") as? Bool ?? true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Catch AppKit terminate→exit paths that bypass quitApp/_exit.
        lf_install_clean_die()
        overlay = OverlayController()
        hub = HubWindowController(
            engine: engine,
            onDictateScratch: { [weak self] in self?.enableScratchMode() },
            onLearnSelection: { [weak self] in self?.learnFromSelection() }
        )
        trackFrontmostApps()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            if let icon = Self.statusBarImage() {
                btn.image = icon
                btn.imagePosition = .imageOnly
            } else {
                btn.title = "LF"
            }
            btn.toolTip = "Tap fn to dictate · Hold LF / Ctrl+Option · Right-click = menu"
            btn.sendAction(on: [.leftMouseDown, .leftMouseUp, .rightMouseDown])
            btn.target = self
            btn.action = #selector(statusButtonEvent)
        }

        menu = buildMenu()
        // Do NOT assign statusItem.menu — left-click is push-to-talk.

        hotkey = HotkeyMonitor(
            onHoldPress: { [weak self] in self?.holdStart(stoleFocus: false) },
            onHoldRelease: { [weak self] in self?.holdEnd() },
            onTapToggle: { [weak self] in self?.toggleListen() }
        )

        overlay.show("Starting…")
        bootstrapPermissionsThenArm()

        DispatchQueue.global().async { [weak self] in
            let s = self?.engine.loadModels() ?? "fail"
            DispatchQueue.main.async {
                self?.modelsReady = s.contains("asr=whisper")
                if Permissions.onboardingStep(modelsReady: self?.modelsReady ?? false) == .ready {
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
        _ = Permissions.requestListenEvents()
        _ = hotkey.start()
        refreshPermissionOnboarding(requestMicrophoneIfNeeded: true)
    }

    private func refreshPermissionOnboarding(requestMicrophoneIfNeeded: Bool = false) {
        let step = Permissions.onboardingStep(modelsReady: modelsReady)
        if step == .ready {
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
            let fn = hotkey.fnTapArmed ? "tap fn" : "enable Input Monitoring"
            overlay.show(modelsReady ? "Ready — \(fn)" : "Permissions ready — loading models…")
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
        let fn = hotkey.fnTapArmed ? "tap fn" : "Input Monitoring off"
        let ax = Permissions.isAccessibilityTrusted() ? "AX✓" : "AX✗"
        return "Ready — \(fn) · \(ax)\n\(models)"
    }

    /// Menubar menu: a few primary actions up top, everything else grouped into
    /// submenus so the surface stays minimal. Shown on right-click of the status item.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Open Hub", #selector(openHub), key: "h"))
        menu.addItem(item("Set up models (download + load)", #selector(setUpModels)))
        menu.addItem(item("Dictate to Scratch", #selector(toggleScratch)))
        menu.addItem(item("Undo last paste", #selector(undoLastPaste), key: "z"))
        menu.addItem(.separator())

        menu.addItem(submenu("Personalization", [
            item("Learn from selection", #selector(learnFromSelection)),
            item("Add dictionary replacement…", #selector(addDictionaryRule)),
            item("Add voice snippet…", #selector(addSnippet)),
            item("Set writing style for focused app…", #selector(setWritingStyle)),
            item("Polish selected text", #selector(polishSelectedText)),
            .separator(),
            item("Toggle cleanup", #selector(toggleCleanup)),
            item("Toggle live typing", #selector(toggleLiveTyping)),
            item("Toggle app context capture", #selector(toggleContextCapture)),
            .separator(),
            item("Personalization summary", #selector(showPersonalization)),
            item("Recent dictation for focused app", #selector(showRecentDictation)),
        ]))

        menu.addItem(submenu("Models", [
            item("Load models", #selector(loadModels), key: "l"),
            item("Download Whisper base-ru (~141MB)", #selector(downloadWhisper)),
            item("Download Gemma 4 E2B (~3.2GB)", #selector(downloadQwen)),
        ]))

        menu.addItem(submenu("Permissions & Troubleshooting", [
            item("Retry hotkey / permissions", #selector(retryPermissions), key: "r"),
            item("Retry last paste", #selector(retryLastPaste)),
            .separator(),
            item("Open Microphone settings", #selector(openMic)),
            item("Open Accessibility settings", #selector(openAccessibility)),
            item("Open Input Monitoring settings", #selector(openInputMonitoring)),
            item("Fix Accessibility (reset + reopen)", #selector(fixAccessibility)),
            .separator(),
            item("Dump AX context (debug)", #selector(dumpContext)),
        ]))

        menu.addItem(.separator())
        let hint = NSMenuItem(
            title: "Tap fn or hold LF to dictate · release to paste",
            action: nil,
            keyEquivalent: ""
        )
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quitApp), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let sub = NSMenu()
        items.forEach { sub.addItem($0) }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    /// One action to make the app usable: download both models (if missing),
    /// then load them — mirrors the mobile "Get started" flow.
    @objc private func setUpModels() {
        overlay.wake()
        overlay.showProgress(title: "Whisper", percent: 0)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let whisperCtx = DownloadProgressCtx()
            whisperCtx.overlay = self.overlay
            whisperCtx.title = "Whisper"
            let whisper = self.engine.downloadWhisper(progress: whisperCtx)
            if whisper.hasPrefix("error") {
                DispatchQueue.main.async {
                    self.overlay.hideProgress()
                    self.overlay.show("Whisper failed: \(whisper)")
                }
                return
            }
            DispatchQueue.main.async {
                self.overlay.showProgress(title: "Gemma 4 E2B", percent: 0)
            }
            let gemmaCtx = DownloadProgressCtx()
            gemmaCtx.overlay = self.overlay
            gemmaCtx.title = "Gemma 4 E2B"
            let gemma = self.engine.downloadQwen(progress: gemmaCtx)
            if gemma.hasPrefix("error") {
                DispatchQueue.main.async {
                    self.overlay.hideProgress()
                    self.overlay.show("Gemma 4 failed: \(gemma)")
                }
                return
            }
            let summary = self.engine.loadModels()
            DispatchQueue.main.async {
                self.overlay.hideProgress()
                self.modelsReady = summary.contains("asr=whisper")
                self.overlay.show(
                    self.modelsReady ? "Models ready — tap fn to dictate" : summary
                )
            }
        }
    }

    @objc private func openHub() {
        hub.show()
    }

    @objc private func toggleScratch() {
        scratchMode.toggle()
        engine.setDestinationScratch(scratchMode)
        overlay.show(scratchMode ? "Scratch mode — tap fn" : "Paste mode — tap fn")
    }

    private func enableScratchMode() {
        scratchMode = true
        engine.setDestinationScratch(true)
        overlay.show("Scratch mode — tap fn")
    }

    @objc private func learnFromSelection() {
        guard let past = lastPasteLearn?.clean, !past.isEmpty else {
            overlay.show("Dictate something first, then edit + Learn")
            return
        }
        let edited = ContextCollector.selectedText().trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = ContextCollector.focusedFieldValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let use = !edited.isEmpty ? edited : fallback
        guard !use.isEmpty, use != past else {
            overlay.show("Select or edit the pasted text first")
            return
        }
        applyLearn(pasted: past, edited: use)
    }

    private func applyLearn(pasted: String, edited: String) {
        let json = engine.learnFromEdit(pasted: pasted, edited: edited)
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = arr.first,
              let heard = first["heard"] as? String,
              let with = first["replace_with"] as? String
        else {
            overlay.show(json.hasPrefix("error") ? json : "No learnable edit")
            return
        }
        lastLearnedHeard = heard
        overlay.showLearn(message: "Learned: \(heard) → \(with)", onKeep: { [weak self] in
            self?.overlay.show("Kept dictionary rule")
        }, onUndo: { [weak self] in
            guard let self, let h = self.lastLearnedHeard else { return }
            _ = self.engine.undoLearned(heard: h)
            self.overlay.show("Undid: \(h)")
        })
    }

    private func toggleListen() {
        if listening {
            holdEnd()
        } else {
            holdStart(stoleFocus: false)
        }
    }

    private func armLearnWatch(clean: String, raw: String) {
        let now = Date()
        lastPasteLearn = (
            clean,
            raw,
            now.addingTimeInterval(2.0), // grace: ignore edits while user starts typing
            now.addingTimeInterval(60)
        )
        learnCandidate = nil
        learnCandidateSince = nil
        learnPollTimer?.invalidate()
        learnPollTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) {
            [weak self] _ in self?.tickLearnWatch()
        }
    }

    private func tickLearnWatch() {
        guard let last = lastPasteLearn else {
            learnPollTimer?.invalidate()
            learnPollTimer = nil
            return
        }
        let now = Date()
        if now > last.deadline {
            lastPasteLearn = nil
            learnCandidate = nil
            learnCandidateSince = nil
            learnPollTimer?.invalidate()
            learnPollTimer = nil
            return
        }
        // Wait out paste settle + first keystrokes.
        guard now >= last.armedAt else { return }

        guard let value = ContextCollector.focusedFieldValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty,
            value != last.clean,
            value.contains(last.clean.prefix(min(12, last.clean.count)))
                || last.clean.contains(value.prefix(min(12, value.count)))
                || abs(value.count - last.clean.count) < max(24, last.clean.count / 2)
        else {
            // Field back to original / unrelated — reset debounce.
            learnCandidate = nil
            learnCandidateSince = nil
            return
        }

        if learnCandidate != value {
            learnCandidate = value
            learnCandidateSince = now
            return
        }
        // Need ~2.8s of identical field value (user paused editing).
        guard let since = learnCandidateSince, now.timeIntervalSince(since) >= 2.8 else {
            return
        }

        let edited = value
        lastPasteLearn = nil
        learnCandidate = nil
        learnCandidateSince = nil
        learnPollTimer?.invalidate()
        learnPollTimer = nil
        applyLearn(pasted: last.clean, edited: edited)
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
                if Permissions.onboardingStep(modelsReady: self?.modelsReady ?? false) == .ready {
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
        runDownload(title: "Gemma 4 E2B") { engine, ctx in
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
        transcriptCache = ""
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
        engine.setDestinationScratch(scratchMode)
        overlay.wake()
        overlay.setListening(true)
        if !engine.startHold() {
            listening = false
            overlay.setListening(false)
            overlay.show("Busy — try again")
            return
        }
        let capture = AudioCapture { [weak self] samples in
            self?.engine.pushAudio(samples)
        }
        audio = capture
        if !capture.start() {
            listening = false
            overlay.setListening(false)
            engine.cancelHold()
            audio = nil
            overlay.show("Mic failed — check Microphone permission")
            return
        }
        overlay.show(scratchMode ? "Listening → Scratch…" : "Listening…")
        NSLog("LocalFlow: Listening started")
        // Hold: Whisper → cache + overlay (no paste). Release: final ASR → Qwen → paste.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while self?.listening == true {
                Thread.sleep(forTimeInterval: 1.6)
                guard let self, self.listening else { continue }
                let partial = self.engine.partialTranscript()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !partial.isEmpty else { continue }
                DispatchQueue.main.sync {
                    guard self.listening else { return }
                    self.transcriptCache = partial
                    self.overlay.show(partial)
                    guard self.liveTypingEnabled, !self.liveBusy else { return }
                    self.liveBusy = true
                    let result = Pasteboard.liveAppend(
                        committed: self.liveCommitted,
                        hypothesis: partial,
                        needsLeadingSpace: self.needsLeadingSpace,
                        restoreApp: self.restoreAppAfterPaste
                    )
                    self.liveCommitted = result.committed
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
        overlay.setListening(false)
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
            let committed: String = DispatchQueue.main.sync {
                self.liveTypingEnabled ? self.liveCommitted : ""
            }
            let result = self.engine.endHold(ctx: ctx)
            let raw = result.raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let clean = result.clean.trimmingCharacters(in: .whitespacesAndNewlines)
            let toScratch = result.destination == "scratch_pad"
            var final = clean.isEmpty ? raw : clean
            if final.hasPrefix("error:") || final.hasPrefix("empty:") {
                DispatchQueue.main.async {
                    self.transcriptCache = ""
                    self.liveCommitted = ""
                    self.restoreAppAfterPaste = nil
                    self.needsLeadingSpace = false
                    self.overlay.show(final)
                }
                return
            }
            if final.isEmpty {
                final = DispatchQueue.main.sync { self.transcriptCache }
            }
            let restore = self.restoreAppAfterPaste

            if toScratch {
                DispatchQueue.main.async {
                    self.transcriptCache = ""
                    self.liveCommitted = ""
                    self.restoreAppAfterPaste = nil
                    self.needsLeadingSpace = false
                    self.overlay.wake()
                    self.overlay.show(final.isEmpty ? "No speech" : "Saved to Scratch")
                    self.hub.refresh()
                }
                return
            }

            if final.isEmpty, result.pressEnter {
                Pasteboard.postEnter()
                DispatchQueue.main.async {
                    self.transcriptCache = ""
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
                self.transcriptCache = ""
                self.liveCommitted = ""
                self.restoreAppAfterPaste = nil
                self.needsLeadingSpace = false
                self.overlay.wake()
                if final.isEmpty {
                    self.overlay.show("No speech — tap fn again")
                } else if out.result == .copied && !out.axTrusted {
                    self.overlay.show("Copied — Cmd+V\nFix Accessibility")
                } else {
                    self.overlay.show(final)
                    if out.result == .pasted {
                        self.armLearnWatch(clean: final, raw: raw)
                    }
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
