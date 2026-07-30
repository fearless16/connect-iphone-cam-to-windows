import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    private let streamer = CameraStreamer()
    private var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let cameraViewController = CameraViewController(streamer: streamer)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = cameraViewController
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        streamer.stop()
    }
}
