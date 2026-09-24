import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        let window = UIWindow(windowScene: windowScene)

        let nav = UINavigationController(rootViewController: HomeViewController())
        // Large titles read as an oversized header on a screen this small; keep the
        // standard compact bar throughout the app.
        nav.navigationBar.prefersLargeTitles = false

        // If the app was purged from the background (common under memory pressure),
        // this is a cold launch — restore the last page the person was on instead of
        // dropping them back at Home.
        if let lastURL = SessionStore.shared.restoreURL() {
            let browser = BrowserViewController(
                startURL: lastURL,
                restoreInteractionState: SessionStore.shared.restoreInteractionState()
            )
            nav.pushViewController(browser, animated: false)
        }

        window.rootViewController = nav
        self.window = window
        window.makeKeyAndVisible()
    }
}
