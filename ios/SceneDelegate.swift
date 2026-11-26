import UIKit

/// UIScene lifecycle (required by UIKit for apps built with SDKs after iOS 26,
/// TN3187). The single window shows the app-wide camera pipeline that
/// AppDelegate owns, so a scene reconnect never creates a second camera.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene,
              let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = CameraViewController(streamer: appDelegate.streamer)
        window.makeKeyAndVisible()
        self.window = window
    }
}
