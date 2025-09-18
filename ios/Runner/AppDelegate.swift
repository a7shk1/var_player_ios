// ios/Runner/AppDelegate.swift
import UIKit
import Flutter

@UIApplicationMain
class AppDelegate: FlutterAppDelegate {
  private let channelName = "com.varplayer.app/links"
  private var initialLink: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    // Flutter setup
    let controller: FlutterViewController = window?.rootViewController as! FlutterViewController
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: controller.binaryMessenger)

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "getInitialLink":
        result(self.initialLink)
      case "clearInitialLink":
        self.initialLink = nil
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // varplayer://
  override func application(_ app: UIApplication, open url: URL,
                            options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
    handleIncoming(url: url)
    return true
  }

  // Universal Links (إذا فعلتها لاحقًا)
  override func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                            restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL {
      handleIncoming(url: url)
      return true
    }
    return false
  }

  private func handleIncoming(url: URL) {
    // خزّن أول رابط كـ initialLink
    if initialLink == nil { initialLink = url.absoluteString }

    // بثّه مباشرة لو التطبيق مفتوح
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: channelName, binaryMessenger: controller.binaryMessenger)
      channel.invokeMethod("onNewIntent", arguments: url.absoluteString)
    }
  }
}
