import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    private var browser: BrowserContainerViewController?

    /// Lets a standalone PWA window hand a navigation back to the main browser.
    func browserForExternalOpen() -> BrowserContainerViewController? { browser }
    private var lastAppliedTheme: AppTheme = Settings.shared.appTheme

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        ContentBlocker.shared.rebuild()

        let window = UIWindow(windowScene: windowScene)
        self.window = window
        buildRootViewController(in: window)
        window.makeKeyAndVisible()

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: Settings.didChange, object: nil)

        if Settings.shared.torForNewTabs { TorManager.shared.start() }
        handle(connectionOptions.urlContexts)
        FavoritePreloader.shared.start()
    }

    /// Builds (or rebuilds) the whole browser UI against the current theme.
    /// Simpler and more reliable than teaching every individual screen to
    /// live-restyle itself when the theme changes — everything just gets
    /// constructed fresh, already reading the new Theme.* values.
    private func buildRootViewController(in window: UIWindow) {
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

        window.overrideUserInterfaceStyle = Theme.isDark ? .dark : .light
        window.tintColor = Theme.accent
        window.rootViewController = nav
    }

    @objc private func settingsChanged() {
        guard Settings.shared.appTheme != lastAppliedTheme, let window else { return }
        lastAppliedTheme = Settings.shared.appTheme
        browser?.persist()
        UIView.transition(with: window, duration: 0.25, options: .transitionCrossDissolve) {
            self.buildRootViewController(in: window)
        }
    }

    /// Links shared to Undirect (share sheet, Shortcuts, other apps) arrive
    /// as undirect://open?url=… or undirect://open?text=…
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        handle(URLContexts)
    }

    private func handle(_ contexts: Set<UIOpenURLContext>) {
        guard let incoming = contexts.first?.url, incoming.scheme?.lowercased() == "undirect",
              let items = URLComponents(url: incoming, resolvingAgainstBaseURL: false)?.queryItems else { return }
        let target: URL?
        if let link = items.first(where: { $0.name == "url" })?.value {
            target = browser?.url(from: link)
        } else if let text = items.first(where: { $0.name == "text" })?.value {
            // Shared text often wraps a link ("look at this: https://…").
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let embedded = detector?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.url
            target = embedded ?? browser?.url(from: text)
        } else {
            target = nil
        }
        guard let target else { return }
        AppLog.shared.log("Opened shared link: \(target.host ?? target.absoluteString)", category: "app")
        browser?.openTab(url: target)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        browser?.appDidEnterBackground()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        browser?.persist()
    }
}
