import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    /// One camera pipeline for the app's lifetime. SceneDelegate shows it in
    /// the window; a scene that reconnects attaches to the same pipeline.
    let streamer = CameraStreamer()

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    func applicationWillTerminate(_ application: UIApplication) {
        streamer.stop()
    }
}
