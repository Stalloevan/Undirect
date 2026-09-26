import UIKit
import WebKit

/// Runs an installed PWA in a clean, app-like window: no address bar, themed
/// status area, and links that leave the app's scope get bounced back to the
/// normal browser instead of trapping the person in a chromeless view. This
/// is Undirect's stand-in for a real home-screen web app, since a sideloaded
/// app can't place a true icon on the home screen.
final class StandalonePWAViewController: UIViewController {

    private let pwa: InstalledPWA
    private let pwaTab: Tab
    private let header = UIView()
    private let titleLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .bar)

    init(pwa: InstalledPWA) {
        self.pwa = pwa
        self.pwaTab = Tab(isTor: false)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var themeColor: UIColor {
        pwa.themeColorHex.flatMap(UIColor.init(hex:)) ?? Theme.bar
    }
    private var backgroundColor: UIColor {
        pwa.backgroundColorHex.flatMap(UIColor.init(hex:)) ?? Theme.background
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = backgroundColor
        pwaTab.delegate = self
        pwaTab.scopeEscapeHandler = { [weak self] url in
            guard let self, !self.pwa.inScope(url) else { return false }
            self.escapeScope(url)
            return true
        }

        header.backgroundColor = themeColor
        titleLabel.text = pwa.name
        titleLabel.textColor = themeColor.isLight ? .black : .white
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textAlignment = .center

        // A slim control row: close (done) + reload, so the app-like window
        // isn't a trap but still reads as standalone.
        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        closeButton.tintColor = titleLabel.textColor
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)

        let menuButton = UIButton(type: .system)
        menuButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        menuButton.tintColor = titleLabel.textColor
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [
            UIAction(title: "Reload", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.pwaTab.webView.reload() },
            UIAction(title: "Open in Browser", image: UIImage(systemName: "safari")) { [weak self] _ in self?.openInBrowser() },
            UIAction(title: "Uninstall App", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                guard let self else { return }
                PWAStore.shared.remove(id: self.pwa.id)
                self.dismiss(animated: true)
            }
        ])

        let webView = pwaTab.webView
        progressView.progressTintColor = themeColor.isLight ? .darkGray : .white
        progressView.trackTintColor = .clear

        for v in [header, webView, progressView] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        for v in [closeButton, titleLabel, menuButton] { v.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(v) }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),

            closeButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            closeButton.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -6),
            closeButton.widthAnchor.constraint(equalToConstant: 40),
            closeButton.heightAnchor.constraint(equalToConstant: 32),

            menuButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            menuButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 40),
            menuButton.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: menuButton.leadingAnchor, constant: -4),

            progressView.topAnchor.constraint(equalTo: header.bottomAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),

            webView.topAnchor.constraint(equalTo: header.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        webView.isOpaque = false
        webView.backgroundColor = backgroundColor

        if let url = pwa.startURLValue { pwaTab.load(url) }

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            self?.progressView.progress = Float(wv.estimatedProgress)
            self?.progressView.isHidden = wv.estimatedProgress >= 1
        }
    }

    private var progressObservation: NSKeyValueObservation?

    override var preferredStatusBarStyle: UIStatusBarStyle { themeColor.isLight ? .darkContent : .lightContent }

    private func openInBrowser() {
        let url = pwaTab.webView.url ?? pwa.startURLValue
        dismiss(animated: true) { [weak self] in
            guard let url, let scene = self?.view.window?.windowScene,
                  let browser = (scene.delegate as? SceneDelegate)?.browserForExternalOpen() else { return }
            browser.openTab(url: url)
        }
    }
}

extension StandalonePWAViewController: TabDelegate {
    func tabDidChange(_ pwaTab: Tab) {
        if let title = pwaTab.webView.title, !title.isEmpty { /* keep app name, not page title */ }
    }
    func tab(_ pwaTab: Tab, toast message: String) {}
    func tab(_ pwaTab: Tab, openInNewTab url: URL) { escapeScope(url) }
    func tab(_ pwaTab: Tab, openInBackgroundTab url: URL) { escapeScope(url) }
    func tab(_ pwaTab: Tab, share url: URL) {
        present(UIActivityViewController(activityItems: [url], applicationActivities: nil), animated: true)
    }
    func tab(_ pwaTab: Tab, openInTorTab url: URL) { escapeScope(url) }
    func tab(_ pwaTab: Tab, blockedPopupTo url: URL) {}
    func tab(_ pwaTab: Tab, foundInstallableManifest manifest: WebAppManifest) {}
    func tab(_ pwaTab: Tab, createPopupWith configuration: WKWebViewConfiguration, url: URL) -> WKWebView? {
        escapeScope(url); return nil
    }
    func tabDidRequestClose(_ pwaTab: Tab) { dismiss(animated: true) }
    func tab(_ pwaTab: Tab, didPick selector: String, label: String) {}
    func presenter(for pwaTab: Tab) -> UIViewController? { self }

    /// A navigation outside the installed app's scope opens in the normal
    /// browser, so the standalone window only ever shows the app itself.
    func escapeScope(_ url: URL) {
        dismiss(animated: true) { [weak self] in
            guard let scene = self?.view.window?.windowScene,
                  let browser = (scene.delegate as? SceneDelegate)?.browserForExternalOpen() else { return }
            browser.openTab(url: url)
        }
    }
}

extension UIColor {
    var isLight: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.65
    }
}
