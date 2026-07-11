import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    private let streamer = CameraStreamer()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Step 1: no UI, just start capturing + encoding.
        streamer.start()
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        streamer.stop()
    }
}
