import UIKit
import Flutter
import GoogleMaps
import UserNotifications

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Maps SDK key for iOS. This is a different key from the web one — make
    // sure "Maps SDK for iOS" is enabled for it in Google Cloud, or the map
    // renders as a blank grey grid with no error.
    GMSServices.provideAPIKey("AIzaSyCafDNuXc-KfId9CDGjlsb3Dx5CiJO3h-E")

    // Without this, iOS silently swallows notifications that arrive while the
    // app is in the foreground — geofence and trip alerts would only appear
    // when the app was backgrounded. FlutterAppDelegate already implements the
    // delegate methods that flutter_local_notifications and firebase_messaging
    // rely on; it just has to be registered.
    UNUserNotificationCenter.current().delegate = self

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
