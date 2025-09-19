import UIKit
import Flutter

@UIApplicationMain
class AppDelegate: FlutterAppDelegate {

  private let channelName = "com.varplayerios/links"
  private var methodChannel: FlutterMethodChannel?
  private var pendingInitialLink: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    // Flutter
    let controller : FlutterViewController = window?.rootViewController as! FlutterViewController
    methodChannel = FlutterMethodChannel(name: channelName, binaryMessenger: controller.binaryMessenger)

    methodChannel?.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else { return }
      switch call.method {
      case "getInitialLink":
        result(self.pendingInitialLink)
      case "clearInitialLink":
        self.pendingInitialLink = nil
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // استلام رابط التشغيل عند الإقلاع (لو التطبيق مفتوح برابط)
    if let url = launchOptions?[.url] as? URL {
      self.pendingInitialLink = url.absoluteString
    }

    // iOS 13+ قد يستخدم SceneDelegate لفتح الروابط، بس نضمن الطريقتين
    let res = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    GeneratedPluginRegistrant.register(with: self)
    return res
  }

  // iOS 9..12: openURL
  override func application(_ app: UIApplication,
                            open url: URL,
                            options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
    handleIncoming(url: url)
    return true
  }

  // iOS 13+: scene delegate route — نضمن الإرسال للقناة أيضًا
  override func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                            restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL {
      handleIncoming(url: url)
      return true
    }
    return false
  }

  private func handleIncoming(url: URL) {
    let link = url.absoluteString
    // إذا بعدنا ما سلّمنا initialLink للـ Dart:
    if pendingInitialLink == nil {
      pendingInitialLink = link
    }
    // إذا Flutter شغّال، نبث onNewIntent
    methodChannel?.invokeMethod("onNewIntent", arguments: link)
  }
}
