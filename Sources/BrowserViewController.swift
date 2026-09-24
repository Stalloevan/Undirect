import UIKit
import WebKit

class BrowserViewController: UIViewController {

    private let startURL: URL
    private var webView: WKWebView!
    private let progressView = UIProgressView(progressViewStyle: .default)
    private var progressObservation: NSKeyValueObservation?
    /// True when this screen was created to host a pop-up WKWebView that WebKit itself
    /// is already navigating — in that case we must NOT call webView.load ourselves.
    private let isHostingSystemProvidedPopup: Bool

    /// The host of the page currently considered "current" for comparing redirect destinations.
    private var currentHost: String? {
        WhitelistStore.normalize(webView.url?.host ?? startURL.host ?? "")
    }

    init(startURL: URL, configuration: WKWebViewConfiguration? = nil) {
        self.startURL = startURL
        self.isHostingSystemProvidedPopup = configuration != nil
        super.init(nibName: nil, bundle: nil)
        setupWebView(configuration: configuration)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupWebView(configuration: WKWebViewConfiguration?) {
        let config = configuration ?? WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true // we intercept & decide ourselves
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
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

        if !isHostingSystemProvidedPopup {
            webView.load(URLRequest(url: startURL))
        }

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Trust Site",
            style: .plain,
            target: self,
            action: #selector(trustCurrentSite)
        )
    }

    @objc private func trustCurrentSite() {
        guard let host = webView.url?.host else { return }
        WhitelistStore.shared.add(host: host)
        showToast("Whitelisted \(WhitelistStore.normalize(host))")
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
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
        ])
        label.setContentHuggingPriority(.required, for: .horizontal)
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

        // A tap the person made on a link is normal browsing, not an unwanted redirect.
        let isUserInitiatedLinkTap = navigationAction.navigationType == .linkActivated

        if isWhitelisted || isUserInitiatedLinkTap || sameHostAsCurrent || !isMainFrame {
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

        guard WhitelistStore.shared.isWhitelisted(host: normalizedDestination) else {
            showToast("Blocked pop-up to \(normalizedDestination)")
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
