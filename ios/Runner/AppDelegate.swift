import UIKit
import Flutter
import GoogleMaps // 1. ADD THIS

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 2. ADD THIS LINE (Gamitin ang iOS Key mo)
    GMSServices.provideAPIKey("AIzaSyCafDNuXc-KfId9CDGjlsb3Dx5CiJO3h-E")
    
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}