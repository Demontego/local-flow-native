import AppKit
import QuartzCore

/// Compact Wispr-like bubble: listening pulse, bottom-center (or near caret).
final class OverlayController {
    private var panel: NSPanel!
    private var label: NSTextField!
    private var bar: NSProgressIndicator!
    private var permissionButton: NSButton!
    private var learnButton: NSButton!
    private var undoButton: NSButton!
    private var pulse: NSView!
    private var permissionAction: (() -> Void)?
    private var learnAction: (() -> Void)?
    private var undoAction: (() -> Void)?
    private var snoozed = false
    private var listening = false
    private var pulseTimer: Timer?
    private let width: CGFloat = 280
    private let heightIdle: CGFloat = 44
    private let heightTall: CGFloat = 96

    init() {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let origin = bottomCenterOrigin(in: screen, height: heightIdle)
        panel = NSPanel(
            contentRect: NSRect(x: origin.x, y: origin.y, width: width, height: heightIdle),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.alphaValue = 0.92

        let content = panel.contentView!
        content.wantsLayer = true
        content.layer?.cornerRadius = 22
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.72).cgColor

        pulse = NSView(frame: NSRect(x: 14, y: 14, width: 16, height: 16))
        pulse.wantsLayer = true
        pulse.layer?.cornerRadius = 8
        pulse.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.85).cgColor
        pulse.isHidden = true
        content.addSubview(pulse)

        label = NSTextField(frame: NSRect(x: 38, y: 10, width: width - 70, height: 24))
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 1, alpha: 0.94)
        label.stringValue = "Local Flow"
        content.addSubview(label)

        bar = NSProgressIndicator(frame: NSRect(x: 14, y: 8, width: width - 48, height: 6))
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 100
        bar.doubleValue = 0
        bar.isIndeterminate = false
        bar.isHidden = true
        content.addSubview(bar)

        permissionButton = NSButton(frame: NSRect(x: 14, y: 8, width: width - 48, height: 26))
        permissionButton.bezelStyle = .rounded
        permissionButton.target = self
        permissionButton.action = #selector(runPermissionAction)
        permissionButton.isHidden = true
        content.addSubview(permissionButton)

        learnButton = NSButton(frame: NSRect(x: 14, y: 8, width: 120, height: 26))
        learnButton.bezelStyle = .rounded
        learnButton.title = "Keep"
        learnButton.target = self
        learnButton.action = #selector(runLearnAction)
        learnButton.isHidden = true
        content.addSubview(learnButton)

        undoButton = NSButton(frame: NSRect(x: 140, y: 8, width: 120, height: 26))
        undoButton.bezelStyle = .rounded
        undoButton.title = "Undo"
        undoButton.target = self
        undoButton.action = #selector(runUndoAction)
        undoButton.isHidden = true
        content.addSubview(undoButton)

        content.addSubview(makeCloseButton(height: heightIdle))
        panel.orderFrontRegardless()
    }

    private func makeCloseButton(height: CGFloat) -> NSButton {
        let close = NSButton(frame: NSRect(x: width - 30, y: height - 28, width: 22, height: 22))
        close.bezelStyle = .circular
        close.isBordered = false
        close.wantsLayer = true
        close.layer?.cornerRadius = 11
        close.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.18).cgColor
        if let img = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close") {
            close.image = img.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            )
            close.imagePosition = .imageOnly
            close.contentTintColor = .white
        } else {
            close.title = "✕"
            close.contentTintColor = .white
        }
        close.target = self
        close.action = #selector(dismiss)
        return close
    }

    func wake() { snoozed = false }

    func hideForPaste() {
        panel.orderOut(nil)
    }

    @objc func dismiss() {
        snoozed = true
        setListening(false)
        panel.orderOut(nil)
    }

    func setListening(_ on: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.listening = on
            self.pulse.isHidden = !on
            self.pulseTimer?.invalidate()
            self.pulseTimer = nil
            if on {
                self.pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) {
                    [weak self] _ in
                    guard let self else { return }
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.35
                        self.pulse.animator().alphaValue = self.pulse.alphaValue < 0.6 ? 1 : 0.35
                    }
                }
            } else {
                self.pulse.alphaValue = 1
            }
        }
    }

    func show(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.snoozed else { return }
            self.resize(tall: false)
            self.bar.isHidden = true
            self.permissionButton.isHidden = true
            self.learnButton.isHidden = true
            self.undoButton.isHidden = true
            self.permissionAction = nil
            self.learnAction = nil
            self.undoAction = nil
            self.label.stringValue = text
            self.label.frame = NSRect(x: self.listening ? 38 : 14, y: 10, width: self.width - 50, height: 24)
            self.reposition()
            self.panel.orderFrontRegardless()
        }
    }

    func showLearn(message: String, onKeep: @escaping () -> Void, onUndo: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snoozed = false
            self.resize(tall: true)
            self.bar.isHidden = true
            self.permissionButton.isHidden = true
            self.label.stringValue = message
            self.label.frame = NSRect(x: 14, y: 40, width: self.width - 40, height: 40)
            self.learnAction = onKeep
            self.undoAction = onUndo
            self.learnButton.isHidden = false
            self.undoButton.isHidden = false
            self.reposition()
            self.panel.orderFrontRegardless()
        }
    }

    func showPermission(
        message: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snoozed = false
            self.resize(tall: true)
            self.bar.isHidden = true
            self.learnButton.isHidden = true
            self.undoButton.isHidden = true
            self.label.stringValue = message
            self.label.frame = NSRect(x: 14, y: 40, width: self.width - 40, height: 40)
            self.permissionButton.title = actionTitle
            self.permissionAction = action
            self.permissionButton.isHidden = false
            self.reposition()
            self.panel.orderFrontRegardless()
        }
    }

    @objc private func runPermissionAction() { permissionAction?() }
    @objc private func runLearnAction() { learnAction?() }
    @objc private func runUndoAction() { undoAction?() }

    func showProgress(title: String, percent: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snoozed = false
            self.resize(tall: true)
            let pct = max(0, min(100, percent))
            self.bar.isHidden = false
            self.permissionButton.isHidden = true
            self.learnButton.isHidden = true
            self.undoButton.isHidden = true
            self.bar.doubleValue = Double(pct)
            self.label.stringValue = "\(title) \(pct)%"
            self.label.frame = NSRect(x: 14, y: 40, width: self.width - 40, height: 40)
            self.reposition()
            self.panel.orderFrontRegardless()
        }
    }

    func hideProgress() {
        DispatchQueue.main.async { [weak self] in
            self?.bar.isHidden = true
        }
    }

    private func resize(tall: Bool) {
        let h = tall ? heightTall : heightIdle
        var f = panel.frame
        f.size.height = h
        panel.setFrame(f, display: true)
        contentCorner()
    }

    private func contentCorner() {
        panel.contentView?.layer?.cornerRadius = listening || panel.frame.height <= heightIdle + 1
            ? 22 : 14
    }

    private func bottomCenterOrigin(in screen: NSRect, height: CGFloat) -> NSPoint {
        NSPoint(
            x: screen.midX - width / 2,
            y: screen.minY + 56
        )
    }

    private func reposition() {
        let h = panel.frame.height
        if let caret = ContextCollector.focusedFieldScreenRect(), caret.width > 0 {
            let x = min(max(caret.midX - width / 2, 8), (NSScreen.main?.visibleFrame.maxX ?? 800) - width - 8)
            let y = max(caret.minY - h - 8, 40)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(bottomCenterOrigin(in: screen, height: h))
        }
    }
}
