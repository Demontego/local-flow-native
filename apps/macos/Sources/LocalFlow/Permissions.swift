import ApplicationServices
import AVFoundation
import AppKit
import CoreGraphics

enum Permissions {
    private static let axSettingsOpenedKey = "lwf.axSettingsOpenedOnce"
    private static let onboardingDoneKey = "lwf.onboardingV2Done"

    enum OnboardingStep: Equatable {
        case requestMicrophone
        case openMicrophoneSettings
        case openAccessibilitySettings
        case openInputMonitoringSettings
        case downloadModels
        case ready

        var message: String {
            switch self {
            case .requestMicrophone:
                "Allow Microphone to dictate"
            case .openMicrophoneSettings:
                "Microphone is off. Enable it in System Settings"
            case .openAccessibilitySettings:
                "Enable Accessibility to paste into any app"
            case .openInputMonitoringSettings:
                "Enable Input Monitoring so Tap fn works"
            case .downloadModels:
                "Download Whisper (+ Gemma for cleanup), then Load models"
            case .ready:
                "Ready — tap fn to dictate"
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
            case .openInputMonitoringSettings:
                "Open Input Monitoring"
            case .downloadModels:
                "Got it"
            case .ready:
                nil
            }
        }
    }

    static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    static func remindAccessibilitySettingsIfNeeded() {
        guard !isAccessibilityTrusted() else { return }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: axSettingsOpenedKey) { return }
        defaults.set(true, forKey: axSettingsOpenedKey)
        openAccessibilitySettings()
    }

    static func canListenEvents() -> Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightListenEventAccess()
        }
        return true
    }

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

    static func onboardingStep(modelsReady: Bool = true) -> OnboardingStep {
        switch micStatus() {
        case .notDetermined:
            return .requestMicrophone
        case .authorized:
            break
        default:
            return .openMicrophoneSettings
        }
        if !isAccessibilityTrusted() {
            return .openAccessibilitySettings
        }
        if !canListenEvents() {
            return .openInputMonitoringSettings
        }
        if !modelsReady {
            return .downloadModels
        }
        return .ready
    }

    static func markOnboardingSeen() {
        UserDefaults.standard.set(true, forKey: onboardingDoneKey)
    }

    static func perform(_ step: OnboardingStep, done: @escaping () -> Void) {
        switch step {
        case .requestMicrophone:
            requestMicrophone { _ in
                DispatchQueue.main.async { done() }
            }
        case .openMicrophoneSettings:
            openMicrophoneSettings()
            done()
        case .openAccessibilitySettings:
            openAccessibilitySettings()
            done()
        case .openInputMonitoringSettings:
            _ = requestListenEvents()
            openInputMonitoringSettings()
            done()
        case .downloadModels:
            markOnboardingSeen()
            done()
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
