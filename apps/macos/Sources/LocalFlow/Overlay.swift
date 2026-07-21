import AppKit

/// Compact top-right translucent HUD with dismiss + download progress.
final class OverlayController {
    private var panel: NSPanel!
    private var label: NSTextField!
    private var bar: NSProgressIndicator!
    private var snoozed = false
    private let width: CGFloat = 340
    private let height: CGFloat = 78

    init() {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let origin = topRightOrigin(in: screen)
        panel = NSPanel(
            contentRect: NSRect(x: origin.x, y: origin.y, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = panel.contentView!
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.58).cgColor

        label = NSTextField(frame: NSRect(x: 12, y: 28, width: width - 52, height: 36))
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.font = .systemFont(ofSize: 13)
        label.textColor = NSColor(calibratedWhite: 1, alpha: 0.92)
        label.stringValue = "Local Flow"
        content.addSubview(label)

        bar = NSProgressIndicator(frame: NSRect(x: 12, y: 12, width: width - 52, height: 8))
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 100
        bar.doubleValue = 0
        bar.isIndeterminate = false
        bar.isHidden = true
        content.addSubview(bar)

        content.addSubview(makeCloseButton())

        panel.orderFrontRegardless()
    }

    private func makeCloseButton() -> NSButton {
        let close = NSButton(frame: NSRect(x: width - 36, y: height - 34, width: 26, height: 26))
        close.bezelStyle = .circular
        close.isBordered = false
        close.wantsLayer = true
        close.layer?.cornerRadius = 13
        close.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.22).cgColor
        if let img = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close"
        ) {
            let cfg = img.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
            )
            close.image = cfg
            close.imagePosition = .imageOnly
            close.contentTintColor = .white
        } else {
            close.title = "✕"
            close.font = .systemFont(ofSize: 14, weight: .bold)
            close.contentTintColor = .white
        }
        close.target = self
        close.action = #selector(dismiss)
        return close
    }

    func wake() { snoozed = false }

    /// Hide HUD so it cannot steal AX focus during paste.
    func hideForPaste() {
        panel.orderOut(nil)
    }

    @objc func dismiss() {
        snoozed = true
        panel.orderOut(nil)
    }

    func show(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.snoozed else { return }
            self.bar.isHidden = true
            self.label.stringValue = text
            self.reposition()
            self.panel.orderFrontRegardless()
        }
    }

    /// Minimal determinate bar while downloading models.
    func showProgress(title: String, percent: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snoozed = false
            let pct = max(0, min(100, percent))
            self.bar.isHidden = false
            self.bar.doubleValue = Double(pct)
            self.label.stringValue = "\(title) \(pct)%"
            self.reposition()
            self.panel.orderFrontRegardless()
        }
    }

    func hideProgress() {
        DispatchQueue.main.async { [weak self] in
            self?.bar.isHidden = true
        }
    }

    private func topRightOrigin(in screen: NSRect) -> NSPoint {
        NSPoint(x: screen.maxX - width - 16, y: screen.maxY - height - 16)
    }

    private func reposition() {
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(topRightOrigin(in: screen))
        }
    }
}
