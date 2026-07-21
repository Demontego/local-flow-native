import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

final class AudioCapture {
    private let onSamples: ([Float]) -> Void
    private let engine = AVAudioEngine()

    init(onSamples: @escaping ([Float]) -> Void) {
        self.onSamples = onSamples
    }

    @discardableResult
    func start() -> Bool {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.channelCount > 0, fmt.sampleRate > 0 else {
            NSLog("Audio start failed: no input device format")
            return false
        }
        let targetRate: Double = 16_000
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buffer, _ in
            guard let self, let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var samples = Array(UnsafeBufferPointer(start: ch, count: n))
            if fmt.sampleRate != targetRate {
                samples = Self.resample(samples, from: fmt.sampleRate, to: targetRate)
            }
            self.onSamples(samples)
        }
        do {
            try engine.start()
            return true
        } catch {
            NSLog("Audio start failed: \(error)")
            input.removeTap(onBus: 0)
            return false
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private static func resample(_ input: [Float], from: Double, to: Double) -> [Float] {
        if from == to { return input }
        let ratio = to / from
        let outCount = max(1, Int(Double(input.count) * ratio))
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let src = Double(i) / ratio
            let i0 = Int(src)
            let i1 = min(i0 + 1, input.count - 1)
            let t = Float(src - Double(i0))
            out[i] = input[i0] * (1 - t) + input[i1] * t
        }
        return out
    }
}

enum Pasteboard {
    private struct LastPaste {
        let text: String
        let bundleID: String
        let createdAt: Date
    }

    private struct RetryPaste {
        let text: String
        let bundleID: String
    }

    private static var lastPaste: LastPaste?
    private static var retryPaste: RetryPaste?
    private static let recoveryLifetime: TimeInterval = 30

    struct Outcome {
        var result: Kind
        var axTrusted: Bool
        var detail: String
    }

    enum Kind: Equatable {
        case pasted
        case copied
    }

    /// Live update result: only advances `committed` when field injection is append-safe.
    struct LiveResult {
        /// Text we believe is actually in the field (from us).
        var committed: String
        /// Latest ASR hypothesis (for overlay), may be ahead of committed on rewrite.
        var hypothesis: String
        var didType: Bool
    }

    /// Append-only live dictation. Never backspaces during hold (avoids eating user text).
    /// When ASR rewrites earlier words, only the overlay advances; field catches up on commitFinal.
    /// `needsLeadingSpace`: char before caret at hold start was a word → first insert gets a leading space.
    static func liveAppend(
        committed: String,
        hypothesis: String,
        needsLeadingSpace: Bool,
        restoreApp: NSRunningApplication?
    ) -> LiveResult {
        let hyp = hypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
        return onMain {
            if let app = restoreApp, !app.isTerminated, isReasonablePasteTarget(app) {
                app.activate()
                spin(0.02)
            }
            guard AXIsProcessTrusted() else {
                log("live: AX off — overlay only")
                return LiveResult(committed: committed, hypothesis: hyp, didType: false)
            }
            guard !hyp.isEmpty else {
                return LiveResult(committed: committed, hypothesis: hyp, didType: false)
            }

            let next: String = {
                if committed.isEmpty {
                    return withLeadingSpace(hyp, needed: needsLeadingSpace)
                }
                if committed.hasPrefix(" "), !hyp.hasPrefix(" ") {
                    return " " + hyp
                }
                return hyp
            }()

            if next == committed {
                return LiveResult(committed: committed, hypothesis: next, didType: false)
            }
            if next.hasPrefix(committed) {
                var suffix = String(next.dropFirst(committed.count))
                if suffix.isEmpty {
                    return LiveResult(committed: committed, hypothesis: next, didType: false)
                }
                suffix = gapSpace(before: committed, after: suffix)
                let typed = committed + suffix
                if typeUnicode(suffix) {
                    log("live: append +\(suffix.count) chars → \(typed.prefix(60))")
                    return LiveResult(committed: typed, hypothesis: typed, didType: true)
                }
                log("live: typeUnicode failed for suffix")
                return LiveResult(committed: committed, hypothesis: next, didType: false)
            }
            // Whisper rewrote the hypothesis — do not delete in-field text mid-hold.
            log("live: skip rewrite committed=\(committed.prefix(40)) hyp=\(next.prefix(40))")
            return LiveResult(committed: committed, hypothesis: next, didType: false)
        }
    }

    /// After release: remove only what we typed (`committed`), paste polished `final`.
    static func commitFinal(
        replacing committed: String,
        with final: String,
        needsLeadingSpace: Bool,
        restoreApp: NSRunningApplication?,
        recordUndo: Bool = true,
        prepareUI: (() -> Void)?
    ) -> Outcome {
        var text = final.trimmingCharacters(in: .whitespacesAndNewlines)
        text = withLeadingSpace(text, needed: needsLeadingSpace || committed.hasPrefix(" "))
        guard !text.isEmpty else {
            return Outcome(result: .copied, axTrusted: AXIsProcessTrusted(), detail: "empty")
        }
        return onMain {
            prepareUI?()
            let trusted = AXIsProcessTrusted()
            log(
                "commitFinal trusted=\(trusted) committed=\(committed.count)c final=\(text.count)c front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")"
            )
            if !trusted {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                retryPaste = RetryPaste(
                    text: text,
                    bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
                )
                return Outcome(result: .copied, axTrusted: false, detail: "AX off")
            }
            if let app = restoreApp, !app.isTerminated, isReasonablePasteTarget(app) {
                app.activate()
                spin(0.1)
            }
            _ = waitModifiersClear(timeout: 1.0)
            spin(0.05)

            if !committed.isEmpty {
                if committed == text {
                    if recordUndo,
                       let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
                        lastPaste = LastPaste(text: text, bundleID: bundleID, createdAt: Date())
                    }
                    log("commitFinal: live already matches final")
                    return Outcome(result: .pasted, axTrusted: true, detail: "unchanged")
                }
                backspace(times: committed.count)
                spin(0.03)
            }

            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            postCmdV()
            spin(0.1)
            if recordUndo,
               let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
                lastPaste = LastPaste(text: text, bundleID: bundleID, createdAt: Date())
                retryPaste = nil
            }
            log("commitFinal: Cmd+V ok")
            return Outcome(result: .pasted, axTrusted: true, detail: "Cmd+V")
        }
    }

    static func undoLastPaste() -> String {
        onMain {
            guard let last = lastPaste,
                  Date().timeIntervalSince(last.createdAt) <= recoveryLifetime
            else {
                return "No recent Local Flow paste to undo"
            }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == last.bundleID else {
                return "Undo skipped: focus changed"
            }
            guard AXIsProcessTrusted(), caretFollows(text: last.text) else {
                return "Undo skipped: caret no longer follows Local Flow text"
            }
            backspace(times: last.text.count)
            lastPaste = nil
            log("undo: removed \(last.text.count) chars")
            return "Undid last Local Flow paste"
        }
    }

    static func retryLastPaste() -> String {
        onMain {
            guard let retry = retryPaste else { return "No failed paste to retry" }
            guard AXIsProcessTrusted() else { return "Retry needs Accessibility" }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == retry.bundleID else {
                return "Retry skipped: focus changed"
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(retry.text, forType: .string)
            postCmdV()
            spin(0.1)
            lastPaste = LastPaste(text: retry.text, bundleID: retry.bundleID, createdAt: Date())
            retryPaste = nil
            log("retry: Cmd+V ok")
            return "Retried Local Flow paste"
        }
    }

    static func postEnter() {
        onMain {
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: true)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: false)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    static func caretFollows(text: String, value: String, location: Int) -> Bool {
        guard location >= text.utf16.count else { return false }
        let prefix = value.utf16.prefix(location)
        return String(decoding: prefix.suffix(text.utf16.count), as: UTF16.self) == text
    }

    private static func caretFollows(text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef
        else { return false }
        let focused = unsafeBitCast(focusedRef, to: AXUIElement.self)
        var valueRef: CFTypeRef?
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &valueRef) == .success,
              AXUIElementCopyAttributeValue(
                  focused,
                  kAXSelectedTextRangeAttribute as CFString,
                  &rangeRef
              ) == .success,
              let value = valueRef as? String,
              let rangeRef
        else { return false }
        let range = unsafeBitCast(rangeRef, to: AXValue.self)
        var selected = CFRange()
        guard AXValueGetValue(range, .cfRange, &selected), selected.length == 0 else { return false }
        return caretFollows(text: text, value: value, location: selected.location)
    }

    private static func withLeadingSpace(_ text: String, needed: Bool) -> String {
        guard needed, !text.isEmpty else { return text }
        if text.first?.isWhitespace == true { return text }
        return " " + text
    }

    /// Insert a space when two word tokens would otherwise glue together.
    private static func gapSpace(before: String, after: String) -> String {
        guard let a = before.last, let b = after.first else { return after }
        if a.isWhitespace || a.isNewline { return after }
        if b.isWhitespace || b.isNewline { return after }
        if ".,;:!?)]}»\"'".contains(b) { return after }
        let wordish: (Character) -> Bool = { $0.isLetter || $0.isNumber }
        if wordish(a) || ")]}\"»".contains(a), wordish(b) {
            return " " + after
        }
        return after
    }

    private static func onMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        var value: T!
        DispatchQueue.main.sync { value = body() }
        return value
    }

    private static func isReasonablePasteTarget(_ app: NSRunningApplication) -> Bool {
        guard let bid = app.bundleIdentifier else { return false }
        let skip = [
            "com.apple.finder",
            "com.apple.controlcenter",
            "com.apple.systemuiserver",
            "com.apple.NotificationCenter",
            Bundle.main.bundleIdentifier ?? "",
        ]
        return !skip.contains(bid)
    }

    @discardableResult
    private static func typeUnicode(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        for ch in text {
            var chars = Array(String(ch).utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else { return false }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }

    private static func backspace(times: Int) {
        guard times > 0 else { return }
        for _ in 0..<times {
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x33, keyDown: true)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x33, keyDown: false)
            down?.flags = []
            up?.flags = []
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    private static func postCmdV() {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func waitModifiersClear(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let flags = CGEventSource.flagsState(.hidSystemState)
            let blocking = flags.contains(.maskControl)
                || flags.contains(.maskAlternate)
                || flags.contains(.maskCommand)
                || flags.contains(.maskShift)
            if !blocking { return true }
            spin(0.02)
        }
        return false
    }

    private static func spin(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private static func log(_ msg: String) {
        NSLog("LocalFlow %@", msg)
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".cache/local-flow-native")
        let path = (dir as NSString).appendingPathComponent("paste.log")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path),
               let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
            {
                defer { try? h.close() }
                h.seekToEndOfFile()
                h.write(data)
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
