import Cocoa
import CoreGraphics

/// Hold Ctrl+Option (same as Python Local Flow).
///
/// Uses `CGEventSource.flagsState` polling — does **not** need Input Monitoring.
/// CGEvent taps often fail silently after install (TCC), so they are not the primary path.
final class HotkeyMonitor {
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var held = false
    private var timer: Timer?
    private(set) var isArmed = false

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
    }

    @discardableResult
    func start() -> Bool {
        if timer != nil {
            isArmed = true
            return true
        }
        // ~60 Hz is enough for hold-to-talk; cheap flags read.
        let t = Timer(timeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        isArmed = true
        NSLog("LocalFlow: hotkey armed via flagsState poll (Ctrl+Option)")
        return true
    }

    @discardableResult
    func rearm() -> Bool {
        timer?.invalidate()
        timer = nil
        held = false
        return start()
    }

    private func tick() {
        // hidSystemState = hardware modifiers, independent of focused app / Input Monitoring.
        let flags = CGEventSource.flagsState(.hidSystemState)
        let want = flags.contains(.maskControl) && flags.contains(.maskAlternate)
        if want && !held {
            held = true
            NSLog("LocalFlow: hotkey PRESS (Ctrl+Option)")
            onPress()
        } else if !want && held {
            held = false
            NSLog("LocalFlow: hotkey RELEASE")
            onRelease()
        }
    }
}
