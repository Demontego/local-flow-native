import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "ai.localflow/native",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "applicationDataDirectory":
        let appGroup = FileManager.default.containerURL(
          forSecurityApplicationGroupIdentifier: "group.ai.localflow.app"
        )
        let directory = (appGroup ?? FileManager.default.urls(
          for: .applicationSupportDirectory,
          in: .userDomainMask
        )[0]).appendingPathComponent("LocalFlow", isDirectory: true)
        do {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          result(directory.path)
        } catch {
          result(FlutterError(code: "data_directory", message: error.localizedDescription, details: nil))
        }
      case "keyboardExtensionAvailable":
        result(true)
      case "openInputSettings":
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
          result(FlutterError(code: "settings_url", message: "Settings URL unavailable", details: nil))
          return
        }
        UIApplication.shared.open(url)
        result(nil)
      case "setModelsReady":
        UserDefaults(suiteName: "group.ai.localflow.app")?.set(
          call.arguments as? Bool ?? false,
          forKey: "modelsReady"
        )
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
