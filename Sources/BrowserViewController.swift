import UIKit
import WebKit

class BrowserViewController: UIViewController {

    private let startURL: URL
    private(set) var webView: WKWebView!
    private let progressView = UIProgressView(progressViewStyle: .default)
    private var progressObservation: NSKeyValueObservation?
    private var canGoBackObservation: NSKeyValueObservation?
    private var canGoForwardObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?

    /// True when this screen was created to host a pop-up WKWebView that WebKit itself
    /// is already navigating — in that case we must NOT call webView.load ourselves.
    private let isHostingSystemProvidedPopup: Bool

    /// Restored scroll/back-forward-history state from a previous session, if any.
    private let restoreInteractionState: Any?

    /// All controls live in the bottom toolbar; the nav bar only shows the title
    /// and the standard back button.
    private let backButton = UIBarButtonItem(image: UIImage(systemName: "chevron.left"), style: .plain, target: nil, action: nil)
    private let forwardButton = UIBarButtonItem(image: UIImage(systemName: "chevron.right"), style: .plain, target: nil, action: nil)
    private let favoriteButton = UIBarButtonItem(image: UIImage(systemName: "star"), style: .plain, target: nil, action: nil)
    private let trustButton = UIBarButtonItem(image: UIImage(systemName: "checkmark.shield"), style: .plain, target: nil, action: nil)

    /// Timestamp of the most recent real tap/touch the person made on the page.
    /// Used to let a redirect chain that genuinely started from a tap keep
    /// running (many sites use JS `onclick` handlers rather than real `<a>`
    /// navigation, which WKWebView reports as navigationType `.other`, not
    /// `.linkActivated` — indistinguishable from a script-driven redirect
    /// without this signal).
    private var lastUserGestureAt: Date?
    private let gestureGraceInterval: TimeInterval = 2.0
    private let gestureHandler = GestureMessageProxy()

    /// The host of the page currently considered "current" for comparing redirect destinations.
    private var currentHost: String? {
        WhitelistStore.normalize(webView.url?.host ?? startURL.host ?? "")
    }

    init(startURL: URL, configuration: WKWebViewConfiguration? = nil, restoreInteractionState: Any? = nil) {
        self.startURL = startURL
        self.isHostingSystemProvidedPopup = configuration != nil
        self.restoreInteractionState = restoreInteractionState
        super.init(nibName: nil, bundle: nil)
        gestureHandler.owner = self
        setupWebView(configuration: configuration)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "undirectGesture")
    }

    private func setupWebView(configuration: WKWebViewConfiguration?) {
        let config: WKWebViewConfiguration
        if let configuration {
            // A system-provided popup configuration must be used as-is; just make
            // sure our theming + gesture-tracking scripts are present on it too.
            config = configuration
            WebEngine.installTheming(on: config)
        } else {
            config = WebEngine.makeConfiguration()
        }
        config.userContentController.add(gestureHandler, name: "undirectGesture")
        config.userContentController.addUserScript(WKUserScript(
            source: Self.gestureTrackingScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = nil
        title = startURL.host

        webView.translatesAutoresizingMaskIntoConstraints = false
        progressView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        view.addSubview(progressView)

        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            webView.topAnchor.constraint(equalTo: progressView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            guard let self else { return }
            self.progressView.progress = Float(webView.estimatedProgress)
            self.progressView.isHidden = webView.estimatedProgress >= 1.0
        }
        canGoBackObservation = webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
            self?.backButton.isEnabled = webView.canGoBack
        }
        canGoForwardObservation = webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
            self?.forwardButton.isEnabled = webView.canGoForward
        }
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            self?.title = webView.url?.host ?? self?.startURL.host
            self?.updateToggleButtons()
        }

        backButton.target = self
        backButton.action = #selector(goBack)
        forwardButton.target = self
        forwardButton.action = #selector(goForward)
        favoriteButton.target = self
        favoriteButton.action = #selector(toggleFavorite)
        trustButton.target = self
        trustButton.action = #selector(toggleTrust)

        toolbarItems = [
            backButton,
            .flexibleSpace(),
            favoriteButton,
            .fixedSpace(24),
            trustButton,
            .flexibleSpace(),
            forwardButton
        ]
        navigationController?.setToolbarHidden(false, animated: false)
        updateToggleButtons()

        if !isHostingSystemProvidedPopup {
            if let restoreInteractionState {
                webView.interactionState = restoreInteractionState
            } else {
                webView.load(URLRequest(url: startURL))
            }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(persistSessionState),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Also persist when navigating away inside the app (e.g. back to Home),
        // not just on backgrounding.
        persistSessionState()
    }

    @objc private func persistSessionState() {
        guard let webView else { return }
        SessionStore.shared.save(url: webView.url ?? startURL, interactionState: webView.interactionState)
    }

    @objc private func goBack() { webView.goBack() }
    @objc private func goForward() { webView.goForward() }

    @objc private func toggleFavorite() {
        guard let url = webView.url else { return }
        let wasFavorite = FavoritesStore.shared.isFavorite(url: url)
        // Favoriting is purely a bookmark — it never touches the whitelist.
        FavoritesStore.shared.toggle(url: url, title: webView.title ?? url.host ?? url.absoluteString)
        updateToggleButtons()
        showToast(wasFavorite ? "Removed from favorites" : "Added to favorites")
    }

    @objc private func toggleTrust() {
        guard let host = webView.url?.host else { return }
        let normalized = WhitelistStore.normalize(host)
        if WhitelistStore.shared.isWhitelisted(host: normalized) {
            WhitelistStore.shared.remove(host: normalized)
            showToast("Removed \(normalized) from whitelist")
        } else {
            WhitelistStore.shared.add(host: normalized)
            showToast("Whitelisted \(normalized)")
        }
        updateToggleButtons()
    }

    private func updateToggleButtons() {
        guard let url = webView.url else { return }
        let isFavorite = FavoritesStore.shared.isFavorite(url: url)
        favoriteButton.image = UIImage(systemName: isFavorite ? "star.fill" : "star")

        let isTrusted = WhitelistStore.shared.isWhitelisted(host: url.host)
        trustButton.image = UIImage(systemName: isTrusted ? "checkmark.shield.fill" : "checkmark.shield")
    }

    /// Called by GestureMessageProxy whenever the page reports a real tap/touch.
    fileprivate func registerUserGesture() {
        lastUserGestureAt = Date()
    }

    private func showToast(_ message: String) {
        let label = UILabel()
        label.text = message
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        label.numberOfLines = 0
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        let bottomAnchor = (navigationController?.isToolbarHidden == false)
            ? (navigationController?.toolbar.topAnchor ?? view.safeAreaLayoutGuide.bottomAnchor)
            : view.safeAreaLayoutGuide.bottomAnchor

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
        label.layoutMargins = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        UIView.animate(withDuration: 0.25, animations: {
            label.alpha = 1
        }) { _ in
            UIView.animate(withDuration: 0.25, delay: 1.6, options: [], animations: {
                label.alpha = 0
            }) { _ in
                label.removeFromSuperview()
            }
        }
    }

    /// Listens for real user interaction on the page (not synthetic events) and
    /// reports it to native code, so genuinely tap-driven navigation chains
    /// (including sites that route taps through JS instead of real `<a>` links)
    /// aren't mistaken for unattended redirects.
    fileprivate static let gestureTrackingScript = """
    (function () {
      function ping() {
        try { window.webkit.messageHandlers.undirectGesture.postMessage(1); } catch (e) {}
      }
      document.addEventListener('pointerdown', ping, true);
      document.addEventListener('touchstart', ping, true);
      document.addEventListener('click', ping, true);
    })();
    """
}

/// Thin WKScriptMessageHandler that only weakly references its owning
/// BrowserViewController, so WKUserContentController's strong retain of the
/// handler can't create a retain cycle.
private final class GestureMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: BrowserViewController?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.registerUserGesture()
    }
}

// MARK: - WKNavigationDelegate (blocks unwanted redirects)

extension BrowserViewController: WKNavigationDelegate {

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let destinationHost = navigationAction.request.url?.host else {
            decisionHandler(.allow)
            return
        }

        let normalizedDestination = WhitelistStore.normalize(destinationHost)
        let isWhitelisted = WhitelistStore.shared.isWhitelisted(host: normalizedDestination)
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let sameHostAsCurrent = currentHost == nil || normalizedDestination == currentHost

        // A tap the person made on a link, or a back/forward history navigation,
        // is normal browsing, not an unwanted redirect.
        let isUserInitiatedLinkTap = navigationAction.navigationType == .linkActivated
        let isHistoryNavigation = navigationAction.navigationType == .backForward

        // Many sites navigate via JS `onclick` handlers rather than real <a>
        // taps, which WebKit reports identically to an unattended redirect
        // (navigationType .other). If the person genuinely tapped the page
        // very recently, let this navigation — and any further redirect hop
        // that follows quickly after it — through, extending the grace window
        // each time so the whole chain resolves, until it goes quiet.
        let recentGesture = lastUserGestureAt.map { Date().timeIntervalSince($0) < gestureGraceInterval } ?? false

        if isWhitelisted || isUserInitiatedLinkTap || isHistoryNavigation || sameHostAsCurrent || !isMainFrame || recentGesture {
            if recentGesture {
                lastUserGestureAt = Date()
            }
            decisionHandler(.allow)
            return
        }

        // Main-frame navigation to a different, non-whitelisted domain that the person
        // did not directly tap (navigationType .other/.formSubmitted/.reload etc, i.e. a
        // script- or server-driven redirect) — this is exactly the behavior we block.
        decisionHandler(.cancel)
        showToast("Blocked redirect to \(normalizedDestination)")
    }
}

// MARK: - WKUIDelegate (blocks new tabs / window.open popups)

extension BrowserViewController: WKUIDelegate {

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let destinationURL = navigationAction.request.url,
              let destinationHost = destinationURL.host else {
            return nil
        }
        let normalizedDestination = WhitelistStore.normalize(destinationHost)
        let recentGesture = lastUserGestureAt.map { Date().timeIntervalSince($0) < gestureGraceInterval } ?? false

        guard WhitelistStore.shared.isWhitelisted(host: normalizedDestination) || recentGesture else {
            showToast("Blocked pop-up to \(normalizedDestination)")
            return nil
        }

        // Whitelisted (or a genuine recent tap): honor the pop-up by pushing a
        // proper browser screen that owns the WKWebView WebKit created for us
        // (required whenever this delegate method returns a non-nil view).
        let popupVC = BrowserViewController(startURL: destinationURL, configuration: configuration)
        navigationController?.pushViewController(popupVC, animated: true)
        return popupVC.webView
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }
}
