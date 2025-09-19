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

    // سجل إضافات Flutter أولاً
    GeneratedPluginRegistrant.register(with: self)

    // أمسك الـ FlutterViewController بأمان
    guard let controller = window?.rootViewController as? FlutterViewController else {
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // قناة دارت <-> iOS
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

    // إذا التطبيق انفتح برابط
    if let url = launchOptions?[.url] as? URL {
      self.pendingInitialLink = url.absoluteString
    }

    // لازم يرجع super
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // iOS 9..12: فتح via URL scheme
  override func application(_ app: UIApplication,
                            open url: URL,
                            options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
    handleIncoming(url: url)
    return true
  }

  // iOS 13+ (Universal links)
  override func application(_ application: UIApplication,
                            continue userActivity: NSUserActivity,
                            restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
       let url = userActivity.webpageURL {
      handleIncoming(url: url)
      return true
    }
    return false
  }

  private func handleIncoming(url: URL) {
    let link = url.absoluteString
    if pendingInitialLink == nil { pendingInitialLink = link }
    methodChannel?.invokeMethod("onNewIntent", arguments: link)
  }
}
