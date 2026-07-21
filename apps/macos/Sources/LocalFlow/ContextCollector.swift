import AppKit
import ApplicationServices

/// Rich AX context for cleanup (Time / Telegram / Cursor / generic windows).
enum ContextCollector {
    private static let chatLimit = 8
    private static let textSnippet = 240

    static func gather() -> DictationCtx {
        var ctx = DictationCtx()
        if let app = NSWorkspace.shared.frontmostApplication {
            ctx.appName = app.localizedName ?? ""
            ctx.bundleId = app.bundleIdentifier ?? ""
        }
        fillWindowTitle(&ctx)
        fillFocusedField(&ctx)
        if isChatApp(ctx) || isEditorApp(ctx) {
            scrapeMessenger(&ctx)
            if ctx.chatLines.count < 4 {
                harvestWebArea(&ctx)
            }
            if ctx.chatLines.count < 4 {
                harvestVisibleText(&ctx)
            }
        } else {
            harvestVisibleText(&ctx)
        }
        // Always expose window in channel_hint for Qwen if nothing better.
        if ctx.channelHint.isEmpty, let w = ctxWindowTitle() {
            ctx.channelHint = w
        }
        sanitizePlaceholders(&ctx)
        // Prepend a stable context line so cleanup always sees the surface.
        let surface = "Window: \(ctx.appName) | \(ctx.channelHint.isEmpty ? "—" : ctx.channelHint)"
        if !ctx.chatLines.contains(where: { $0.hasPrefix("Window:") }) {
            ctx.chatLines.insert(String(surface.prefix(200)), at: 0)
        }
        NSLog(
            "LocalFlow context app=%@ window=%@ messages=%d",
            ctx.bundleId,
            ctx.channelHint,
            ctx.chatLines.count
        )
        return ctx
    }

    /// True if inserting at the caret should start with a space (letter/digit before cursor).
    static func cursorNeedsLeadingSpace() -> Bool {
        let sys = AXUIElementCreateSystemWide()
        guard let raw = axCopy(sys, kAXFocusedUIElementAttribute as CFString) else { return false }
        let focused = unsafeBitCast(raw, to: AXUIElement.self)
        guard let value = axOptionalString(focused, kAXValueAttribute as CFString), !value.isEmpty
        else { return false }

        var loc = value.utf16.count
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success, let rangeRef {
            var cfRange = CFRange()
            if AXValueGetValue(rangeRef as! AXValue, .cfRange, &cfRange) {
                loc = cfRange.location
            }
        }
        guard loc > 0 else { return false }
        let utf16 = Array(value.utf16)
        let idx = min(loc, utf16.count) - 1
        guard idx >= 0, idx < utf16.count else { return false }
        guard let ch = String(utf16CodeUnits: [utf16[idx]], count: 1).first else { return false }
        if ch.isWhitespace || ch.isNewline { return false }
        if "([{「«\"'".contains(ch) { return false }
        return ch.isLetter || ch.isNumber || ch == "," || ch == ";" || ch == ":" || ch == "."
    }

    private static func isChatApp(_ ctx: DictationCtx) -> Bool {
        let blob = (ctx.appName + " " + ctx.bundleId).lowercased()
        let hints = [
            "telegram", "slack", "discord", "whatsapp", "messages", "messenger",
            "mattermost", "teams", "element", "signal",
            "chatgpt", "claude",
        ]
        return hints.contains { blob.contains($0) }
    }

    private static func isEditorApp(_ ctx: DictationCtx) -> Bool {
        let blob = (ctx.appName + " " + ctx.bundleId).lowercased()
        let hints = [
            "cursor", "todesktop", "vscode", "visual studio code", "com.microsoft.vscode",
            "xcode", "sublime", "zed", "windsurf", "antigravity",
        ]
        return hints.contains { blob.contains($0) }
    }

    private static func fillWindowTitle(_ ctx: inout DictationCtx) {
        if let title = ctxWindowTitle(), !title.isEmpty {
            ctx.channelHint = String(title.prefix(160))
        }
    }

    private static func ctxWindowTitle() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appEl,
            kAXFocusedWindowAttribute as CFString,
            &winRef
        ) == .success, let winRef {
            let win = unsafeBitCast(winRef, to: AXUIElement.self)
            let title = axString(win, kAXTitleAttribute as CFString)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        // Fallback: main window
        var mainRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appEl,
            kAXMainWindowAttribute as CFString,
            &mainRef
        ) == .success, let mainRef {
            let win = unsafeBitCast(mainRef, to: AXUIElement.self)
            let title = axString(win, kAXTitleAttribute as CFString)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return nil
    }

    private static func fillFocusedField(_ ctx: inout DictationCtx) {
        let sys = AXUIElementCreateSystemWide()
        guard let raw = axCopy(sys, kAXFocusedUIElementAttribute as CFString) else { return }
        let focused = unsafeBitCast(raw, to: AXUIElement.self)

        ctx.selectedText = String(axString(focused, kAXSelectedTextAttribute as CFString).prefix(textSnippet))

        if let value = axOptionalString(focused, kAXValueAttribute as CFString), !value.isEmpty {
            applyFieldValue(&ctx, value: value)
            return
        }
        if let ta = findRole(focused, role: "AXTextArea", maxDepth: 6),
           let value = axOptionalString(ta, kAXValueAttribute as CFString), !value.isEmpty
        {
            applyFieldValue(&ctx, value: value)
        }
    }

    private static func applyFieldValue(_ ctx: inout DictationCtx, value: String) {
        let v = value
        ctx.beforeText = String(v.suffix(textSnippet))
        if let last = v.split(whereSeparator: \.isNewline).last.map(String.init), !last.isEmpty {
            ctx.beforeText = String(last.suffix(textSnippet))
        }
    }

    /// Generic visible text (Telegram bubbles, Cursor UI labels, etc.).
    private static func harvestVisibleText(_ ctx: inout DictationCtx) {
        guard let root = appRoot() else { return }
        var lines: [String] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var nodes = 0
        while let (el, depth) = stack.popLast(), nodes < 2200, lines.count < 30 {
            nodes += 1
            let role = axString(el, kAXRoleAttribute as CFString)
            if role == "AXStaticText" || role == "AXTextField" || role == "AXTextArea" {
                let val = axString(el, kAXValueAttribute as CFString)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let title = axString(el, kAXTitleAttribute as CFString)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                for cand in [val, title] where cand.count >= 2 && cand.count <= 280 {
                    if isUINoise(cand) || isPlaceholder(cand) { continue }
                    lines.append(cand)
                }
            }
            if depth < 20, let kids = axChildren(el) {
                for c in kids.suffix(40) { stack.append((c, depth + 1)) }
            }
        }
        var seen = Set(ctx.chatLines)
        for line in lines where !seen.contains(line) {
            seen.insert(line)
            ctx.chatLines.append(String(line.prefix(240)))
        }
        ctx.chatLines = Array(ctx.chatLines.suffix(chatLimit))
    }

    private static func scrapeMessenger(_ ctx: inout DictationCtx) {
        guard let root = appRoot() else { return }
        var messages: [String] = []
        var channelHints: [String] = []
        var inputValues: [String] = []
        var stack: [(AXUIElement, Int, String)] = [(root, 0, "")]
        var nodes = 0

        while let (el, depth, region) = stack.popLast(), nodes < 3000 {
            nodes += 1
            let role = axString(el, kAXRoleAttribute as CFString)
            let desc = axString(el, kAXDescriptionAttribute as CFString).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = axString(el, kAXTitleAttribute as CFString).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = axString(el, kAXValueAttribute as CFString).trimmingCharacters(in: .whitespacesAndNewlines)

            var next = region
            let low = desc.lowercased()
            if low.contains("message details") { next = "details" }
            else if low.contains("message input") { next = "input" }
            else if low.contains("channel sidebar") || low.contains("channel navigator") { next = "sidebar" }

            if next == "details", !desc.isEmpty {
                if let parsed = parseMessageDescription(desc) {
                    messages.append(parsed)
                } else if looksLikeMessageBlob(desc) {
                    messages.append(String(desc.prefix(280)))
                }
            }

            if role == "AXHeading", !title.isEmpty, depth <= 22 {
                if title.lowercased().contains("thread") || title.count < 80 {
                    channelHints.append(title)
                }
            }
            if (role == "AXTextArea" || role == "AXTextField"), !value.isEmpty {
                inputValues.append(value)
            }
            if role == "AXWebArea", title.contains(" - ") {
                channelHints.append(title)
            }

            if depth < 28, let kids = axChildren(el) {
                for child in kids.reversed() {
                    stack.append((child, depth + 1, next))
                }
            }
        }

        if messages.count < 3 {
            messages.append(contentsOf: harvestMessageDescriptions(root))
        }

        var seen = Set<String>()
        var clean: [String] = []
        for m in messages {
            let line = m.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if line.count < 3 || seen.contains(line) || isUINoise(line) { continue }
            seen.insert(line)
            clean.append(String(line.prefix(300)))
        }
        if !clean.isEmpty {
            ctx.chatLines = Array(clean.suffix(chatLimit))
        }

        for hint in channelHints.reversed() {
            if !isUINoise(hint) {
                ctx.channelHint = String(hint.prefix(120))
                break
            }
        }

        if ctx.beforeText.isEmpty {
            for v in inputValues.reversed() where !isPlaceholder(v) {
                ctx.beforeText = String(v.suffix(textSnippet))
                break
            }
        }
    }

    private static func harvestWebArea(_ ctx: inout DictationCtx) {
        guard let root = appRoot() else { return }
        var lines: [String] = []
        var stack: [(AXUIElement, Int, Bool)] = [(root, 0, false)]
        var nodes = 0
        while let (el, depth, inWeb) = stack.popLast(), nodes < 2500, lines.count < 40 {
            nodes += 1
            let role = axString(el, kAXRoleAttribute as CFString)
            let now = inWeb || role == "AXWebArea"
            if role == "AXWebArea", ctx.channelHint.isEmpty {
                let title = axString(el, kAXTitleAttribute as CFString).trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { ctx.channelHint = String(title.prefix(120)) }
            }
            if now || ctx.bundleId.lowercased().contains("claude") {
                for attr in [kAXValueAttribute as String, kAXDescriptionAttribute as String, kAXTitleAttribute as String] {
                    let val = axString(el, attr as CFString)
                        .split(whereSeparator: \.isWhitespace)
                        .joined(separator: " ")
                    if val.count < 12 || val.count > 400 || isUINoise(val) { continue }
                    if looksLikeMessageBlob(val), let parsed = parseMessageDescription(val) {
                        lines.append(parsed)
                        continue
                    }
                    if role == "AXButton" || role == "AXMenuItem" || role == "AXLink", val.count < 40 {
                        continue
                    }
                    lines.append(val)
                }
            }
            if depth < 24, let kids = axChildren(el) {
                for child in kids.suffix(50) {
                    stack.append((child, depth + 1, now))
                }
            }
        }
        var seen = Set(ctx.chatLines)
        for line in lines where !seen.contains(line) {
            seen.insert(line)
            ctx.chatLines.append(line)
        }
        ctx.chatLines = Array(ctx.chatLines.suffix(chatLimit))
    }

    private static func harvestMessageDescriptions(_ root: AXUIElement) -> [String] {
        var out: [String] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var nodes = 0
        while let (el, depth) = stack.popLast(), nodes < 2500, out.count < 40 {
            nodes += 1
            let desc = axString(el, kAXDescriptionAttribute as CFString)
            if let parsed = parseMessageDescription(desc) {
                out.append(parsed)
            }
            if depth < 28, let kids = axChildren(el) {
                for c in kids { stack.append((c, depth + 1)) }
            }
        }
        return out
    }

    private static func parseMessageDescription(_ desc: String) -> String? {
        let text = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        let markers = [" replied, ", " wrote, "]
        guard let marker = markers.first(where: { text.contains($0) }) else { return nil }
        let parts = text.components(separatedBy: marker)
        guard parts.count >= 2 else { return nil }
        let left = parts[0]
        var body = parts.dropFirst().joined(separator: marker)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        if let r = body.range(of: #"\s+(sweat smile|smile|emoji)\b.*$"#, options: .regularExpression) {
            body = String(body[..<r.lowerBound])
        }
        let author = left.split(separator: ",").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard author.count >= 2, body.count >= 1 else { return nil }
        if isUINoise(author) || isUINoise(body) { return nil }
        return "\(author): \(String(body.prefix(240)))"
    }

    private static func looksLikeMessageBlob(_ desc: String) -> Bool {
        !isUINoise(desc) && desc.hasPrefix("At ")
            && (desc.contains(" wrote, ") || desc.contains(" replied, "))
    }

    private static func isPlaceholder(_ v: String) -> Bool {
        let low = v.lowercased().replacingOccurrences(of: "\u{00a0}", with: " ")
        return low.hasPrefix("reply to ")
            || low.hasPrefix("write to ")
            || low.hasPrefix("write a ")
            || low.contains("message…")
            || low.contains("message...")
    }

    private static func sanitizePlaceholders(_ ctx: inout DictationCtx) {
        if isPlaceholder(ctx.beforeText) { ctx.beforeText = "" }
        if isPlaceholder(ctx.selectedText) { ctx.selectedText = "" }
    }

    private static func isUINoise(_ line: String) -> Bool {
        let low = line.lowercased()
        let noise = [
            "complimentary region", "channel sidebar", "navigator region", "emoji picker",
            "upload files", "send a message", "send later", "additional actions", "filter by",
            "select to ", "context menu", "public channel", "private channel", "find channels",
            "drafts", "favorites", "following", "unreads",
        ]
        return noise.contains { low.contains($0) }
    }

    private static func appRoot() -> AXUIElement? {
        if let app = NSWorkspace.shared.frontmostApplication {
            return AXUIElementCreateApplication(app.processIdentifier)
        }
        return nil
    }

    private static func axString(_ el: AXUIElement, _ attr: CFString) -> String {
        axOptionalString(el, attr) ?? ""
    }

    private static func axOptionalString(_ el: AXUIElement, _ attr: CFString) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &v) == .success, let v else { return nil }
        return "\(v)"
    }

    private static func axCopy(_ el: AXUIElement, _ attr: CFString) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &v) == .success else { return nil }
        return v
    }

    private static func axChildren(_ el: AXUIElement) -> [AXUIElement]? {
        guard let v = axCopy(el, kAXChildrenAttribute as CFString) else { return nil }
        return v as? [AXUIElement]
    }

    private static func findRole(_ root: AXUIElement, role: String, maxDepth: Int) -> AXUIElement? {
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while let (el, depth) = stack.popLast() {
            if axString(el, kAXRoleAttribute as CFString) == role { return el }
            if depth >= maxDepth { continue }
            if let kids = axChildren(el) {
                for c in kids { stack.append((c, depth + 1)) }
            }
        }
        return nil
    }
}
