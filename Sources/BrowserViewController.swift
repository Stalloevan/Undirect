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

    /// A pop-up web view's configuration frequently shares its underlying
    /// WKUserContentController with its opener, so registering a script message
    /// handler under a fixed name can crash the app the moment a page opens a
    /// pop-up ("attempting to add script handler with name X that already has
    /// been added"). A per-instance unique name makes that collision
    /// impossible regardless of whether the controller is shared.
    private let gestureMessageName = "undirectGesture_\(UUID().uuidString.prefix(8))"
    private let gestureHandler = GestureMessageProxy()

    /// Where and when the person most recently tapped the page.
    private var lastTapPoint: CGPoint?
    private var lastTapAt: Date?

    /// Many "redirect" pages are really an invisible tap-catching overlay: the
    /// first tap opens an ad/redirect *and* the overlay removes itself, so the
    /// *next* tap at the same spot reaches the real link underneath. So instead
    /// of ever letting a blocked navigation through, we keep the block and
    /// resend a synthetic tap at the same coordinates, repeating (bounded)
    /// until a resend doesn't trigger another blocked attempt — which
    /// effectively "clicks through" that layer without ever honoring the
    /// redirect/pop-up itself.
    private var retryChainCount = 0
    private let maxRetryChain = 4
    private let tapAssociationWindow: TimeInterval = 0.6
    private let retryRedispatchDelay: TimeInterval = 0.18

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
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: gestureMessageName)
    }

    private func setupWebView(configuration: WKWebViewConfiguration?) {
        let config: WKWebViewConfiguration
        if let configuration {
            // A system-provided popup configuration must be used as-is; just make
            // sure our theming script is present on it too.
            config = configuration
            WebEngine.installTheming(on: config)
        } else {
            config = WebEngine.makeConfiguration()
        }
        config.userContentController.add(gestureHandler, name: gestureMessageName)
        config.userContentController.addUserScript(WKUserScript(
            source: Self.gestureTrackingScript(messageName: gestureMessageName),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.overrideUserInterfaceStyle = .dark
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
    /// A brand new tap starts a fresh retry chain at that point.
    fileprivate func registerUserGesture(at point: CGPoint) {
        lastTapPoint = point
        lastTapAt = Date()
        retryChainCount = 0
    }

    /// Called when a navigation or pop-up was just blocked. If that block
    /// followed a real, recent tap and we haven't exhausted the retry budget,
    /// resend a synthetic tap at the same point — this is what "clicks
    /// through" a disappearing ad-interstitial layer without ever letting the
    /// redirect/pop-up itself happen.
    private func attemptClickThroughIfWarranted() {
        guard let point = lastTapPoint,
              let tapAt = lastTapAt,
              Date().timeIntervalSince(tapAt) < tapAssociationWindow,
              retryChainCount < maxRetryChain else {
            return
        }
        retryChainCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + retryRedispatchDelay) { [weak self] in
            guard let self, let webView = self.webView else { return }
            webView.evaluateJavaScript(Self.syntheticClickScript(x: point.x, y: point.y), completionHandler: nil)
        }
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

    /// Listens for real user interaction on the page (not synthetic events —
    /// see below) and reports the tap coordinates to native code.
    fileprivate static func gestureTrackingScript(messageName: String) -> String {
        """
        (function () {
          function send(x, y) {
            try { window.webkit.messageHandlers.\(messageName).postMessage({x: x, y: y}); } catch (e) {}
          }
          document.addEventListener('touchstart', function (e) {
            var t = e.changedTouches && e.changedTouches[0];
            if (t) send(t.clientX, t.clientY);
          }, true);
          document.addEventListener('click', function (e) {
            send(e.clientX, e.clientY);
          }, true);
        })();
        """
    }

    /// Re-dispatches a realistic tap at (x, y) in the page, aimed at whatever
    /// element is there *now* — after a blocked overlay has typically already
    /// removed itself — so the real content underneath receives it.
    fileprivate static func syntheticClickScript(x: CGFloat, y: CGFloat) -> String {
        """
        (function () {
          var el = document.elementFromPoint(\(x), \(y));
          if (!el) return;
          var opts = { bubbles: true, cancelable: true, clientX: \(x), clientY: \(y), view: window };
          ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'].forEach(function (type) {
            try {
              var ctor = type.indexOf('pointer') === 0 ? PointerEvent : MouseEvent;
              el.dispatchEvent(new ctor(type, opts));
            } catch (e) {}
          });
        })();
        """
    }
}

/// Thin WKScriptMessageHandler that only weakly references its owning
/// BrowserViewController, so WKUserContentController's strong retain of the
/// handler can't create a retain cycle.
private final class GestureMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: BrowserViewController?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let x = body["x"] as? Double,
              let y = body["y"] as? Double else { return }
        owner?.registerUserGesture(at: CGPoint(x: x, y: y))
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

        if isWhitelisted || isUserInitiatedLinkTap || isHistoryNavigation || sameHostAsCurrent || !isMainFrame {
            decisionHandler(.allow)
            return
        }

        // Main-frame navigation to a different, non-whitelisted domain that the person
        // did not directly tap — this is exactly the behavior we block, always, with
        // no exception for a recent tap. If it followed one, click through it instead.
        decisionHandler(.cancel)
        showToast("Blocked redirect to \(normalizedDestination)")
        attemptClickThroughIfWarranted()
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

        guard WhitelistStore.shared.isWhitelisted(host: normalizedDestination) else {
            showToast("Blocked pop-up to \(normalizedDestination)")
            attemptClickThroughIfWarranted()
            return nil
        }

        // Whitelisted: honor the pop-up by pushing a proper browser screen that owns
        // the WKWebView WebKit created for us (required whenever this delegate method
        // returns a non-nil view).
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
