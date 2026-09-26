import UIKit
import AppIntents
import WebKit

// MARK: - Shortcuts action

/// "Open Immersive" — appears as a native Shortcuts action taking a URL. Runs
/// the site with every Undirect UI element hidden: no sidebar, no address
/// bar, no status bar, no home-indicator hint. Exits on a three-finger tap,
/// or the next time the app returns to the foreground after being
/// backgrounded — iOS gives no way to tell "tapped the Home Screen/App
/// Library/Spotlight icon" apart from "picked from the app switcher", so
/// both are treated the same way here; there's no way to make only the
/// former exit and not the latter.
struct OpenImmersiveIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Immersive in Undirect"
    static var description = IntentDescription("Opens a URL in Undirect with every browser UI element hidden — sidebar, address bar, and status bar all gone. Exit with a three-finger tap, or by leaving and reopening the app.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "URL")
    var url: URL

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            ImmersiveRequest.pendingURL = url
            NotificationCenter.default.post(name: ImmersiveRequest.notification, object: url)
        }
        return .result()
    }
}

/// Hands a requested URL from the Shortcuts action (which runs before the
/// app's UI necessarily exists yet) over to the browser once it's ready.
enum ImmersiveRequest {
    static var pendingURL: URL?
    static let notification = Notification.Name("UndirectImmersiveRequest")
}

// MARK: - Chromeless viewer

/// The full-screen, UI-free presentation itself. Owns no state of its own —
/// it borrows the tab's existing web view and hands it back to the normal
/// browser chrome on exit.
final class ImmersiveViewController: UIViewController {
    private let pwaTab: Tab
    var onExit: (() -> Void)?
    private var wasBackgrounded = false

    init(tab: Tab) {
        self.pwaTab = tab
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }
    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var childForHomeIndicatorAutoHidden: UIViewController? { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let webView = pwaTab.webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(exitTapped))
        threeFingerTap.numberOfTouchesRequired = 3
        view.addGestureRecognizer(threeFingerTap)

        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    @objc private func exitTapped() { onExit?() }

    @objc private func appDidEnterBackground() { wasBackgrounded = true }

    @objc private func appDidBecomeActive() {
        if wasBackgrounded { onExit?() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
