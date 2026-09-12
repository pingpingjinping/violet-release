import UIKit
import Flutter
import flutter_downloader

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var downloadKeepAwake = false
  private var downloadScreenChannel: FlutterMethodChannel?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    FlutterDownloaderPlugin.setPluginRegistrantCallback(registerPlugins)
    if let registrar = self.registrar(forPlugin: "VioletDownloadScreen") {
      let channel = FlutterMethodChannel(name: "xyz.project.violet/downloadScreen", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { [weak self] call, result in
        guard call.method == "setKeepAwake", let enabled = call.arguments as? Bool else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.downloadKeepAwake = enabled
        UIApplication.shared.isIdleTimerDisabled = enabled && UIApplication.shared.applicationState == .active
        result(nil)
      }
      downloadScreenChannel = channel
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // https://stackoverflow.com/a/66997677
  override func applicationWillResignActive(
    _ application: UIApplication
  ) {
    application.isIdleTimerDisabled = false
    let secureKey = "flutter.useSecureMode"
    if UserDefaults.standard.bool(forKey: secureKey) {
      self.window?.isHidden = true
    }
  }
  override func applicationDidBecomeActive(
    _ application: UIApplication
  ) {
    self.window?.isHidden = false
    application.isIdleTimerDisabled = downloadKeepAwake
  }
}

private func registerPlugins(registry: FlutterPluginRegistry) {
  if (!registry.hasPlugin("FlutterDownloaderPlugin")) {
    FlutterDownloaderPlugin.register(with: registry.registrar(forPlugin: "FlutterDownloaderPlugin")!)
  }
}
