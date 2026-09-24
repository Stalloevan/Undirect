import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    private var browser: BrowserContainerViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        ContentBlocker.shared.rebuild()

        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = Theme.bar
        appearance.titleTextAttributes = [.foregroundColor: Theme.text]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().tintColor = Theme.accent

        let browser = BrowserContainerViewController()
        self.browser = browser
        let nav = UINavigationController(rootViewController: browser)
        nav.navigationBar.prefersLargeTitles = false
        nav.setNavigationBarHidden(true, animated: false)

        let window = UIWindow(windowScene: windowScene)
        window.overrideUserInterfaceStyle = .dark
        window.tintColor = Theme.accent
        window.rootViewController = nav
        self.window = window
        window.makeKeyAndVisible()

        if Settings.shared.torForNewTabs { TorManager.shared.start() }
        FavoritePreloader.shared.start()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        browser?.appDidEnterBackground()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        browser?.persist()
    }
}
