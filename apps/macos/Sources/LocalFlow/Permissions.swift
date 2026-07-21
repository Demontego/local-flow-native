import ApplicationServices
import AVFoundation
import AppKit
import CoreGraphics

enum Permissions {
    private static let axSettingsOpenedKey = "lwf.axSettingsOpenedOnce"

    enum OnboardingStep: Equatable {
        case requestMicrophone
        case openMicrophoneSettings
        case openAccessibilitySettings
        case ready

        var message: String {
            switch self {
            case .requestMicrophone:
                "Allow Microphone to dictate"
            case .openMicrophoneSettings:
                "Microphone is off. Enable it in System Settings"
            case .openAccessibilitySettings:
                "Enable Accessibility to paste into any app"
            case .ready:
                "Ready — hold Ctrl+Option (or LF)"
            }
        }

        var actionTitle: String? {
            switch self {
            case .requestMicrophone:
                "Allow Microphone"
            case .openMicrophoneSettings:
                "Open Microphone Settings"
            case .openAccessibilitySettings:
                "Open Accessibility Settings"
            case .ready:
                nil
            }
        }
    }

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

    static func onboardingStep() -> OnboardingStep {
        switch micStatus() {
        case .notDetermined:
            return .requestMicrophone
        case .authorized:
            return isAccessibilityTrusted() ? .ready : .openAccessibilitySettings
        default:
            return .openMicrophoneSettings
        }
    }

    static func perform(_ step: OnboardingStep, done: @escaping () -> Void) {
        switch step {
        case .requestMicrophone:
            requestMicrophone { _ in
                DispatchQueue.main.async { done() }
            }
        case .openMicrophoneSettings:
            openMicrophoneSettings()
        case .openAccessibilitySettings:
            openAccessibilitySettings()
        case .ready:
            break
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
