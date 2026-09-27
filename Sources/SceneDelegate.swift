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
        // The reputation lists load lazily on first use — which used to be
        // the main thread, stalling the first link long-press. Warm them here.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            _ = SiteReputationIndex.categories(for: "warmup.invalid")
        }
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
        for context in contexts {
            if context.url.isFileURL {
                // An HTML file from Files / "Open in Undirect". Copy it if it
                // was opened in place, take it over if iOS handed us a copy.
                browser?.openLocalFile(context.url, move: !context.options.openInPlace)
                continue
            }
            guard let target = Self.target(from: context.url) else {
                AppLog.shared.log("Ignored incoming link: \(context.url.absoluteString.prefix(120))", category: "app")
                continue
            }
            AppLog.shared.log("Opened shared link: \(target.host ?? target.absoluteString)", category: "app")
            // Queued by the browser until its saved tabs are restored, so a
            // cold launch from the share sheet can't lose or bury the link.
            browser?.openExternal(target)
        }
    }

    /// undirect://open?url=… / ?text=… (share sheet, Shortcuts), plus plain
    /// http(s) links handed straight to the app.
    static func target(from incoming: URL) -> URL? {
        let scheme = incoming.scheme?.lowercased()
        if scheme == "http" || scheme == "https" { return incoming }
        guard scheme == "undirect",
              let items = URLComponents(url: incoming, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        if let link = items.first(where: { $0.name == "url" })?.value {
            return webURL(from: link)
        }
        if let text = items.first(where: { $0.name == "text" })?.value {
            // Shared text often wraps a link ("look at this: https://…").
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let embedded = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap(\.url)
                .first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
            return embedded ?? webURL(from: text)
        }
        return nil
    }

    private static func webURL(from raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https", url.host != nil {
            return url
        }
        // Tolerate unencoded characters some apps leave in shared links.
        if let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(.urlQueryAllowed)),
           let url = URL(string: encoded), url.host != nil, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return url
        }
        if !text.contains(" "), text.contains("."), let url = URL(string: "https://" + text), url.host != nil {
            return url
        }
        return Settings.shared.searchURL(for: text)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        browser?.appDidEnterBackground()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        browser?.persist()
    }
}
