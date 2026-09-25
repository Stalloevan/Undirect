import UIKit
import WebKit

protocol TabDelegate: AnyObject {
    func tabDidChange(_ tab: Tab)
    func tab(_ tab: Tab, toast message: String)
    func tab(_ tab: Tab, openInNewTab url: URL)
    func tab(_ tab: Tab, createPopupWith configuration: WKWebViewConfiguration, url: URL) -> WKWebView?
    func tabDidRequestClose(_ tab: Tab)
    func tab(_ tab: Tab, didPick selector: String, label: String)
    func presenter(for tab: Tab) -> UIViewController?
}

final class Tab: NSObject {

    let id: UUID
    let isTor: Bool
    /// Hosts a window.open() web view created by WebKit. Such views share their
    /// opener's content controller, so we never add scripts/handlers/rules to them.
    let isPopup: Bool
    let webView: WKWebView
    weak var delegate: TabDelegate?

    private(set) var pendingURL: URL?
    var favicon: UIImage?

    private let messageName: String
    private let messageProxy: ScriptMessageProxy
    private var observations: [NSKeyValueObservation] = []

    // Redirect / click-through state
    private var lastTapPoint: CGPoint?
    private var lastTapAt: Date?
    private var retryChain = 0
    private let maxRetryChain = 4
    /// A URL the app itself (or the person, via the address bar) asked to load.
    private var expectedURL: URL?
    /// True while a user-initiated navigation hasn't committed yet: server-side
    /// redirects in that chain are what the person asked for, so they're allowed.
    /// Anything a page does after it has committed is treated as page-driven.
    private var userChainActive = false

    private var appliedPaused: Bool?
    private var appliedGeneration = -1

    private static let shorteners: Set<String> = [
        "t.co", "bit.ly", "tinyurl.com", "goo.gl", "ow.ly", "buff.ly", "lnkd.in", "t.ly", "rebrand.ly",
        "is.gd", "dlvr.it", "fb.me", "amzn.to", "spoti.fi", "apple.co", "youtu.be", "g.co", "trib.al"
    ]

    init(isTor: Bool, popupConfiguration: WKWebViewConfiguration? = nil, id: UUID = UUID()) {
        self.id = id
        self.isTor = isTor
        self.isPopup = popupConfiguration != nil
        let name = "undirect_" + String(UUID().uuidString.prefix(8))
        self.messageName = name
        let proxy = ScriptMessageProxy()
        self.messageProxy = proxy

        let config = popupConfiguration ?? WebEngine.makeConfiguration(tor: isTor)
        if popupConfiguration == nil {
            // Unique per-tab name: re-registering a fixed name on a shared
            // controller is what crashed v1.2.
            config.userContentController.add(proxy, contentWorld: .defaultClient, name: name)
            WebEngine.installScripts(on: config.userContentController, messageName: name, tor: isTor)
        }
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        messageProxy.owner = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Full-page swipe-to-navigate is implemented at the container level
        // (BrowserContainerViewController's page pan handler) instead of
        // WebKit's own edge-only gesture, so it works from anywhere on the
        // page, not just the screen edge. Leaving both active would double-
        // navigate on edge swipes since they'd both fire for the same drag.
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.isOpaque = false
        webView.backgroundColor = Theme.background
        webView.scrollView.backgroundColor = Theme.background
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        applyContentRules(for: nil)

        let notify: (WKWebView) -> Void = { [weak self] _ in
            guard let self else { return }
            self.delegate?.tabDidChange(self)
        }
        observations = [
            webView.observe(\.title) { wv, _ in notify(wv) },
            webView.observe(\.url) { wv, _ in notify(wv) },
            webView.observe(\.estimatedProgress) { wv, _ in notify(wv) },
            webView.observe(\.canGoBack) { wv, _ in notify(wv) },
            webView.observe(\.canGoForward) { wv, _ in notify(wv) },
            webView.observe(\.isLoading) { wv, _ in notify(wv) }
        ]
    }

    deinit {
        observations.forEach { $0.invalidate() }
        if !isPopup {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: messageName, contentWorld: .defaultClient)
        }
    }

    // MARK: Public

    var url: URL? { webView.url ?? pendingURL }
    var host: String? { url?.host }
    var isBlank: Bool { webView.url == nil && pendingURL == nil && !webView.isLoading }
    var isWaitingForTor: Bool { pendingURL != nil && isTor && !TorManager.shared.isReady }

    var title: String {
        if let t = webView.title, !t.isEmpty { return t }
        if let h = host { return DomainUtil.normalize(h) }
        return "New Tab"
    }

    var icon: UIImage {
        favicon ?? FaviconStore.monogram(for: host, tor: isTor)
    }

    func load(_ url: URL) {
        expectedURL = url
        if isTor && !TorManager.shared.isReady {
            pendingURL = url
            TorManager.shared.start()
            delegate?.tabDidChange(self)
            return
        }
        pendingURL = nil
        webView.load(URLRequest(url: url))
    }

    func torBecameReady() {
        guard let url = pendingURL else { return }
        pendingURL = nil
        expectedURL = url
        webView.load(URLRequest(url: url))
    }

    func restore(interactionState: Any) {
        webView.interactionState = interactionState
    }

    func reinstallScripts() {
        guard !isPopup else { return }
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        WebEngine.installScripts(on: controller, messageName: messageName, tor: isTor)
    }

    func applyContentRules(for host: String?, force: Bool = false) {
        guard !isPopup else { return }
        let paused = ContentBlocker.shared.paused.contains(host: host ?? webView.url?.host)
        let gen = ContentBlocker.shared.generation + ContentBlocker.shared.ruleLists.count * 1000
        guard force || paused != appliedPaused || gen != appliedGeneration else { return }
        appliedPaused = paused
        appliedGeneration = gen
        ContentBlocker.shared.apply(to: webView.configuration.userContentController, paused: paused)
    }

    func runInClientWorld(_ js: String) {
        webView.evaluateJavaScript(js, in: nil, in: .defaultClient) { _ in }
    }

    func callInClientWorld(_ body: String, completion: @escaping (Any?) -> Void) {
        webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .defaultClient) { result in
            if case .success(let value) = result { completion(value) } else { completion(nil) }
        }
    }

    // MARK: Messages from page scripts

    fileprivate func handle(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "tap":
            guard let x = body["x"] as? Double, let y = body["y"] as? Double else { return }
            lastTapPoint = CGPoint(x: x, y: y)
            lastTapAt = Date()
            retryChain = 0

        case "login":
            guard !isTor, let host = webView.url?.host,
                  !CookieGuard.shared.keptLogins.contains(host: host) else { return }
            CookieGuard.shared.keptLogins.add(host: host)
            delegate?.tab(self, toast: "Keeping you logged in on \(DomainUtil.baseDomain(host))")

        case "failed":
            let hosts = (body["hosts"] as? [String]) ?? []
            let blocked = hosts.filter { ContentBlocker.shared.isBlocked(host: $0) }.count
            BlockStats.shared.increment(.requests, by: blocked)

        case "pick":
            guard let selector = body["selector"] as? String, let label = body["label"] as? String else { return }
            delegate?.tab(self, didPick: selector, label: label)

        default:
            break
        }
    }

    // MARK: Click-through

    /// Keeps blocking, but resends the person's tap at the same spot. Overlays
    /// that hijack the first tap(s) usually remove themselves afterwards, so a
    /// resent tap reaches the real content underneath.
    private func attemptClickThrough() {
        guard Settings.shared.clickThrough, !isPopup,
              let point = lastTapPoint, let tapAt = lastTapAt,
              Date().timeIntervalSince(tapAt) < 1.5,
              retryChain < maxRetryChain else { return }
        retryChain += 1
        lastTapAt = Date()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let js = "return window.__undirectClickThrough ? window.__undirectClickThrough(\(Double(point.x)), \(Double(point.y))) : null;"
            self.callInClientWorld(js) { [weak self] value in
                guard let self,
                      let dict = value as? [String: Any],
                      let href = dict["href"] as? String,
                      let url = URL(string: href),
                      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                      !ContentBlocker.shared.isBlocked(host: url.host) else { return }
                // The overlay is gone and a real link is under the finger: follow it.
                self.load(url)
            }
        }
    }

    private func block(_ kind: StatKind, host: String) {
        BlockStats.shared.increment(kind)
        let what = kind == .popups ? "pop-up" : "redirect"
        delegate?.tab(self, toast: "Blocked \(what) to \(DomainUtil.baseDomain(host))")
        attemptClickThrough()
    }
}

// MARK: - Script message proxy

/// Weak trampoline so WKUserContentController's strong reference can't retain the tab.
final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: Tab?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        owner?.handle(body)
    }
}

// MARK: - Navigation policy

extension Tab: WKNavigationDelegate {

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.allow); return }
        let scheme = url.scheme?.lowercased() ?? ""

        if scheme.isEmpty || ["about", "data", "blob", "javascript"].contains(scheme) {
            decisionHandler(.allow)
            return
        }
        if scheme != "http" && scheme != "https" {
            decisionHandler(.cancel)
            // mailto:, tel:, app links — only when the person actually tapped them.
            if action.navigationType == .linkActivated && !isTor {
                UIApplication.shared.open(url)
            }
            return
        }

        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        guard isMainFrame else { decisionHandler(.allow); return }

        let destHost = url.host ?? ""
        let currentHost = webView.url?.host
        let type = action.navigationType

        if type == .backForward || type == .reload {
            applyContentRules(for: destHost)
            decisionHandler(.allow)
            return
        }

        // Tracker removal: unwrap click-tracking wrappers and strip tracking params.
        if Settings.shared.stripTrackers,
           (action.request.httpMethod ?? "GET").uppercased() == "GET",
           let cleaned = URLCleaner.clean(url), cleaned != url {
            decisionHandler(.cancel)
            BlockStats.shared.increment(.trackers)
            load(cleaned)
            return
        }

        // Something the person typed / picked / we loaded on their behalf.
        if let expected = expectedURL,
           expected == url || DomainUtil.sameSite(expected.host, destHost) {
            expectedURL = nil
            userChainActive = true
            applyContentRules(for: destHost)
            decisionHandler(.allow)
            return
        }

        let trusted = WhitelistStore.shared.isWhitelisted(host: destHost)
            || WhitelistStore.shared.isWhitelisted(host: currentHost)

        // Known ad/tracker domain as a top-level destination: always blocked,
        // even when the page disguises it as a link.
        if !trusted && ContentBlocker.shared.isBlocked(host: destHost) {
            decisionHandler(.cancel)
            block(.redirects, host: destHost)
            return
        }

        let userInitiated = type == .linkActivated || type == .formSubmitted || type == .formResubmitted
        let allowed = trusted
            || userInitiated
            || userChainActive
            || currentHost == nil
            || DomainUtil.sameSite(currentHost, destHost)
            || Self.shorteners.contains(DomainUtil.normalize(currentHost ?? ""))

        if allowed {
            if userInitiated { userChainActive = true }
            applyContentRules(for: destHost)
            decisionHandler(.allow)
            return
        }

        // A page-driven jump to another site after it loaded: block it.
        decisionHandler(.cancel)
        block(.redirects, host: destHost)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        userChainActive = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        userChainActive = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        userChainActive = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        CookieGuard.shared.spoofAnalyticsCookies(in: webView.configuration.websiteDataStore.httpCookieStore)
        loadFavicon()
        delegate?.tabDidChange(self)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    private func loadFavicon() {
        guard let host = webView.url?.host else { return }
        if isTor {
            loadFaviconWithinPage(host: host)
            return
        }
        if let cached = FaviconStore.shared.cached(host: host) {
            favicon = cached
            delegate?.tabDidChange(self)
            return
        }
        let js = "(function(){var l=document.querySelector('link[rel~=\"apple-touch-icon\"]')||document.querySelector('link[rel~=\"icon\"]');return l?l.href:null})()"
        webView.evaluateJavaScript(js) { [weak self] value, _ in
            let hint = (value as? String).flatMap(URL.init(string:))
            FaviconStore.shared.fetch(host: host, hint: hint) { image in
                guard let self, let image, self.webView.url?.host == host else { return }
                self.favicon = image
                self.delegate?.tabDidChange(self)
            }
        }
    }

    /// Fetches the favicon using the page's own `fetch()`, so the request
    /// goes through the same Tor circuit as the rest of the tab instead of a
    /// separate, unproxied URLSession — a plain fetch would otherwise leak
    /// this specific request outside Tor. Nothing is written to disk; the
    /// image only ever lives in memory, matching the rest of a Tor tab.
    private func loadFaviconWithinPage(host: String) {
        let js = """
        var link = document.querySelector('link[rel~="apple-touch-icon"]') || document.querySelector('link[rel~="icon"]');
        var href = link ? link.href : (location.origin + '/favicon.ico');
        try {
          var response = await fetch(href);
          if (!response.ok) return null;
          var blob = await response.blob();
          return await new Promise(function (resolve) {
            var reader = new FileReader();
            reader.onloadend = function () { resolve(reader.result); };
            reader.onerror = function () { resolve(null); };
            reader.readAsDataURL(blob);
          });
        } catch (e) { return null; }
        """
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self, self.webView.url?.host == host,
                  case .success(let value) = result,
                  let dataURL = value as? String,
                  let comma = dataURL.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
                  let image = UIImage(data: data) else { return }
            self.favicon = image
            self.delegate?.tabDidChange(self)
        }
    }
}

// MARK: - Pop-ups and dialogs

extension Tab: WKUIDelegate {

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = action.request.url, let destHost = url.host else { return nil }
        let currentHost = webView.url?.host
        let trusted = WhitelistStore.shared.isWhitelisted(host: destHost)
            || WhitelistStore.shared.isWhitelisted(host: currentHost)

        if trusted {
            // Honour the real window (keeps window.opener for sign-in pop-ups).
            return delegate?.tab(self, createPopupWith: configuration, url: url)
        }

        // A genuine tap on a target=_blank link to a non-ad site opens a normal new tab.
        if action.navigationType == .linkActivated && !ContentBlocker.shared.isBlocked(host: destHost) {
            delegate?.tab(self, openInNewTab: url)
            return nil
        }

        block(.popups, host: destHost)
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        delegate?.tabDidRequestClose(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let presenter = delegate?.presenter(for: self) else { completionHandler(); return }
        let alert = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let presenter = delegate?.presenter(for: self) else { completionHandler(false); return }
        let alert = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard let presenter = delegate?.presenter(for: self) else { completionHandler(nil); return }
        let alert = UIAlertController(title: frame.request.url?.host, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
        presenter.present(alert, animated: true)
    }
}
