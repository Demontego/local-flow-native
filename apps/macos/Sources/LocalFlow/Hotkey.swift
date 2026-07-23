import Cocoa
import CoreGraphics
import QuartzCore

/// Primary: **tap fn/Globe** toggles listen (needs Input Monitoring).
/// Secondary: **hold Ctrl+Option** (flagsState poll — no Input Monitoring).
final class HotkeyMonitor {
    private let onHoldPress: () -> Void
    private let onHoldRelease: () -> Void
    private let onTapToggle: () -> Void

    private var held = false
    private var timer: Timer?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnDownAt: CFTimeInterval?
    private var sawOtherKeyWhileFn = false
    private(set) var isArmed = false
    private(set) var fnTapArmed = false

    /// Tap window for fn (Wispr-like).
    private let tapMaxSeconds: CFTimeInterval = 0.35

    init(
        onHoldPress: @escaping () -> Void,
        onHoldRelease: @escaping () -> Void,
        onTapToggle: @escaping () -> Void
    ) {
        self.onHoldPress = onHoldPress
        self.onHoldRelease = onHoldRelease
        self.onTapToggle = onTapToggle
    }

    @discardableResult
    func start() -> Bool {
        startHoldPoll()
        fnTapArmed = startFnTap()
        isArmed = true
        return true
    }

    @discardableResult
    func rearm() -> Bool {
        stopFnTap()
        timer?.invalidate()
        timer = nil
        held = false
        fnDownAt = nil
        return start()
    }

    private func startHoldPoll() {
        if timer != nil { return }
        let t = Timer(timeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.tickHold()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NSLog("LocalFlow: hotkey armed via flagsState poll (Ctrl+Option hold)")
    }

    private func tickHold() {
        let flags = CGEventSource.flagsState(.hidSystemState)
        let want = flags.contains(.maskControl) && flags.contains(.maskAlternate)
        if want && !held {
            held = true
            NSLog("LocalFlow: hotkey PRESS (Ctrl+Option)")
            onHoldPress()
        } else if !want && held {
            held = false
            NSLog("LocalFlow: hotkey RELEASE")
            onHoldRelease()
        }
    }

    /// CGEvent tap for fn (keycode 63). Requires Input Monitoring.
    @discardableResult
    private func startFnTap() -> Bool {
        if eventTap != nil { return true }
        _ = Permissions.requestListenEvents()
        let mask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let mon = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return mon.handleEvent(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            NSLog("LocalFlow: fn tap failed (enable Input Monitoring)")
            return false
        }
        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("LocalFlow: fn tap-toggle armed (keycode 63)")
        return true
    }

    private func stopFnTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        runLoopSource = nil
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        fnTapArmed = false
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        // kVK_Function = 63 (fn / Globe)
        let isFn = keycode == 63

        if type == .keyDown {
            if isFn {
                fnDownAt = CACurrentMediaTime()
                sawOtherKeyWhileFn = false
            } else if fnDownAt != nil {
                sawOtherKeyWhileFn = true
            }
        } else if type == .keyUp, isFn {
            let down = fnDownAt
            fnDownAt = nil
            if let down,
               !sawOtherKeyWhileFn,
               CACurrentMediaTime() - down <= tapMaxSeconds
            {
                NSLog("LocalFlow: fn TAP toggle")
                DispatchQueue.main.async { [weak self] in
                    self?.onTapToggle()
                }
            }
            sawOtherKeyWhileFn = false
        } else if type == .flagsChanged, isFn {
            // Some keyboards report fn only via flagsChanged.
            let flags = event.flags
            // NX_SECONDARYFNMASK = 1<<23 on Apple keyboards.
            let fnDown = flags.contains(CGEventFlags(rawValue: 1 << 23))
            if fnDown {
                if fnDownAt == nil {
                    fnDownAt = CACurrentMediaTime()
                    sawOtherKeyWhileFn = false
                }
            } else if let down = fnDownAt {
                fnDownAt = nil
                if !sawOtherKeyWhileFn, CACurrentMediaTime() - down <= tapMaxSeconds {
                    NSLog("LocalFlow: fn flags TAP toggle")
                    DispatchQueue.main.async { [weak self] in
                        self?.onTapToggle()
                    }
                }
                sawOtherKeyWhileFn = false
            }
        }
        return Unmanaged.passUnretained(event)
    }
}
