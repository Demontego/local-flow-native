import Cocoa
import FlutterMacOS

/// Platform bridge shared with iOS/Android MethodChannel name.
enum NativeChannel {
  static let name = "ai.localflow/native"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "applicationDataDirectory":
        result(Self.applicationDataDirectory())
      case "keyboardExtensionAvailable", "isImeEnabled":
        result(false)
      case "openInputSettings":
        Self.openPrivacySettings()
        result(nil)
      case "setModelsReady":
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func applicationDataDirectory() -> String {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    let directory = base.appendingPathComponent("LocalFlow", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory.path
  }

  private static func openPrivacySettings() {
    // Microphone privacy pane; user can jump to Accessibility / Input Monitoring.
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    ) {
      NSWorkspace.shared.open(url)
    }
  }
}
