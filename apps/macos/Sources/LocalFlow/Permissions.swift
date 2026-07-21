import ApplicationServices
import AVFoundation
import AppKit
import CoreGraphics

enum Permissions {
    private static let axSettingsOpenedKey = "lwf.axSettingsOpenedOnce"

    static func isAccessibilityTrusted() -> Bool {
        // Silent check — never pass prompt:true here (that dialog every launch).
        AXIsProcessTrusted()
    }

    /// Open System Settings once (no modal AX prompt). TCC sticks only with stable codesign.
    static func remindAccessibilitySettingsIfNeeded() {
        guard !isAccessibilityTrusted() else { return }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: axSettingsOpenedKey) { return }
        defaults.set(true, forKey: axSettingsOpenedKey)
        openAccessibilitySettings()
    }

    /// Input Monitoring (needed for Ctrl+Option via CGEvent tap).
    static func canListenEvents() -> Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightListenEventAccess()
        }
        return true
    }

    /// Request listen access once when arming hotkey — not on every cold start if already decided.
    @discardableResult
    static func requestListenEvents() -> Bool {
        if #available(macOS 10.15, *) {
            if CGPreflightListenEventAccess() { return true }
            return CGRequestListenEventAccess()
        }
        return true
    }

    static func micStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestMicrophone(_ done: @escaping (Bool) -> Void) {
        switch micStatus() {
        case .authorized:
            done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: done)
        default:
            done(false)
        }
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func open(_ url: String) {
        if let u = URL(string: url) {
            NSWorkspace.shared.open(u)
        }
    }
}
