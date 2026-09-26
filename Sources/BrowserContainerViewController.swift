import UIKit
import WebKit

enum SwipeNavDirection { case back, forward }

/// Live state for an in-progress interactive back/forward swipe.
/// `item` is nil for a back-swipe with no more history — that returns the
/// tab to a blank New Tab Page instead of doing nothing.
struct SwipeNavState {
    let direction: SwipeNavDirection
    let item: WKBackForwardListItem?
    let tab: Tab
    let outgoing: UIView
    let incoming: UIView
    let container: UIView
}

final class BrowserContainerViewController: UIViewController {

    private(set) var tabs: [Tab] = []
    private var selectedIndex = 0
    private var currentTab: Tab? { tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil }

    // Chrome — address bar lives at the bottom; back/forward are swipe-only
    // (WKWebView's own edge-swipe gesture, always on).
    private let addressBar = UIView()
    private let addressBarBackdrop = UIView()
    private let addressField = UITextField()
    private let fieldBackground = UIView()
    private let addressIcon = UIButton(type: .system)
    private let reloadButton = UIButton(type: .system)
    private lazy var pageMenuButton = UIButton(type: .system)
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let sidebar = TabSidebarView()
    /// Solid black strip behind the status bar / notch so system icons
    /// always sit on black with white glyphs, whatever the page or theme.
    private let statusBarShield = UIView()
    private let addressGradient = CAGradientLayer()
    private var sidebarWidth: NSLayoutConstraint!
    private let pulloutHandle = PulloutHandleView()
    private var pulloutLeading: NSLayoutConstraint!
    private var pulloutTrailing: NSLayoutConstraint!
    private let contentView = UIView()
    private let ntp = NewTabPageViewController()
    private let torOverlay = TorConnectingView()
    private let pickerBanner = PickerBanner()

    private var sidebarState: SidebarState = Settings.shared.sidebarState

    // Layout constraints that swap when the sidebar moves sides.
    private var sidebarLeading: NSLayoutConstraint!
    private var sidebarTrailing: NSLayoutConstraint!
    private var contentLeadingFromSidebar: NSLayoutConstraint!
    private var contentLeadingFromSafe: NSLayoutConstraint!
    private var contentTrailingFromSidebar: NSLayoutConstraint!
    private var contentTrailingFromSafe: NSLayoutConstraint!
    private var addressBarBottom: NSLayoutConstraint!

    private var pickingTab: Tab?
    private var lastAppliedSidebarPosition: SidebarPosition?
    private var swipeNav: SwipeNavState?
    private var detectedManifest: WebAppManifest?
    private var shownInstallPromptFor: Set<String> = []

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        buildChrome()

        addChild(ntp)
        ntp.view.frame = contentView.bounds
        ntp.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(ntp.view)
        ntp.didMove(toParent: self)
        ntp.onOpen = { [weak self] url, newTab, tor in
            guard let self else { return }
            if newTab { self.openTab(url: url, tor: tor) } else { self.navigate(to: url) }
        }
        ntp.onNewTorTab = { [weak self] in self?.openTab(url: nil, tor: true) }
        ntp.onLaunchPWA = { [weak self] pwa in self?.launchPWA(pwa) }
        ntp.onCustomize = { [weak self] in
            self?.navigationController?.pushViewController(NTPLayoutViewController(), animated: true)
        }

        torOverlay.frame = contentView.bounds
        torOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(torOverlay)
        torOverlay.onCancel = { [weak self] in self?.cancelTorWaitOnCurrentTab() }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(rulesUpdated), name: ContentBlocker.didUpdate, object: nil)
        nc.addObserver(self, selector: #selector(rulesUpdated), name: DomainSetStore.didChange, object: nil)
        nc.addObserver(self, selector: #selector(torStateChanged), name: TorManager.stateDidChange, object: nil)
        nc.addObserver(self, selector: #selector(elementRulesChanged), name: ElementHideStore.didChange, object: nil)
        nc.addObserver(self, selector: #selector(updateChrome), name: FavoritesStore.didChange, object: nil)
        nc.addObserver(self, selector: #selector(settingsChanged), name: Settings.didChange, object: nil)
        nc.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)

        setupPageInteractionAutoHide()
        NotificationCenter.default.addObserver(self, selector: #selector(handleImmersiveRequest(_:)),
                                               name: ImmersiveRequest.notification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleOpenURLRequest),
                                               name: OpenURLRequest.notification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleNewTabRequest),
                                               name: NewTabRequest.notification, object: nil)
        if let pending = ImmersiveRequest.pendingURL {
            ImmersiveRequest.pendingURL = nil
            DispatchQueue.main.async { [weak self] in self?.presentImmersive(url: pending) }
        }
        if let pending = OpenURLRequest.pending {
            OpenURLRequest.pending = nil
            DispatchQueue.main.async { [weak self] in self?.openTab(url: pending.url, tor: pending.tor) }
        }
        if let pendingTor = NewTabRequest.pendingTor {
            NewTabRequest.pendingTor = nil
            DispatchQueue.main.async { [weak self] in self?.openTab(url: nil, tor: pendingTor) }
        }
        restoreSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        Theme.applyBlockShadow(to: fieldBackground)
        // Gradient reaches a little above the bar so the page fades into it.
        let fade: CGFloat = 28
        addressGradient.frame = CGRect(x: 0, y: -fade, width: addressBar.bounds.width, height: addressBar.bounds.height + fade)
        applyBottomInsets()
    }

    /// Bottom space the floating address bar covers, so page content (and
    /// the new tab page) can still scroll fully clear of it.
    private var floatingBarCoverage: CGFloat { 50 + view.safeAreaInsets.bottom }

    private func applyBottomInsets() {
        let inset = floatingBarCoverage
        if let scroll = currentTab?.webView.scrollView, scroll.contentInset.bottom != inset {
            scroll.contentInset.bottom = inset
            scroll.verticalScrollIndicatorInsets.bottom = inset
        }
        let ntpInset = UIEdgeInsets(top: 0, left: 0, bottom: 50, right: 0)
        if ntp.additionalSafeAreaInsets != ntpInset { ntp.additionalSafeAreaInsets = ntpInset }
    }

    /// Tints the floating bar with the current page's own background color
    /// (Safari-style), fading from transparent above into solid at the bottom.
    private func updateAddressBarTint(for tab: Tab) {
        let color = tab.isBlank ? Theme.background : (tab.pageBackgroundColor ?? Theme.background)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        addressGradient.colors = [color.withAlphaComponent(0).cgColor,
                                  color.withAlphaComponent(0.92).cgColor,
                                  color.cgColor]
        CATransaction.commit()
        addressBarBackdrop.backgroundColor = color
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        navigationController?.setToolbarHidden(true, animated: false)
        updateChrome()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    // Always white: the status bar always sits on the black shield.
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: Layout

    private func buildChrome() {
        addressBar.backgroundColor = .clear
        addressGradient.startPoint = CGPoint(x: 0.5, y: 0)
        addressGradient.endPoint = CGPoint(x: 0.5, y: 1)
        addressGradient.locations = [0, 0.45, 1]
        addressBar.layer.insertSublayer(addressGradient, at: 0)
        addressBarBackdrop.backgroundColor = Theme.background
        fieldBackground.backgroundColor = Theme.field
        fieldBackground.layer.cornerRadius = Theme.cornerRadius

        addressIcon.tintColor = Theme.secondaryText
        addressIcon.contentMode = .scaleAspectFit
        addressIcon.accessibilityLabel = "Tor for this tab"
        addressIcon.addAction(UIAction { [weak self] _ in self?.toggleTor() }, for: .touchUpInside)

        addressField.textColor = Theme.text
        addressField.font = .systemFont(ofSize: 15)
        addressField.attributedPlaceholder = NSAttributedString(string: "Search or enter address",
                                                                attributes: [.foregroundColor: Theme.secondaryText])
        addressField.keyboardType = .webSearch
        addressField.returnKeyType = .go
        addressField.autocapitalizationType = .none
        addressField.autocorrectionType = .no
        addressField.keyboardAppearance = Theme.keyboardAppearance
        addressField.delegate = self

        reloadButton.tintColor = Theme.secondaryText
        reloadButton.addAction(UIAction { [weak self] _ in self?.reloadOrStop() }, for: .touchUpInside)

        pageMenuButton.tintColor = Theme.text
        pageMenuButton.setImage(Theme.icon("ellipsis.circle"), for: .normal)
        pageMenuButton.showsMenuAsPrimaryAction = true
        pageMenuButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.pageSettingsElements() ?? [])
        }])
        pageMenuButton.accessibilityLabel = "Page settings"

        progressView.progressTintColor = Theme.accent
        progressView.trackTintColor = .clear

        sidebar.delegate = self
        statusBarShield.backgroundColor = .black

        contentView.backgroundColor = Theme.background
        contentView.clipsToBounds = true

        for v in [contentView, sidebar, addressBarBackdrop, addressBar, progressView, pickerBanner, pulloutHandle, statusBarShield] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        for v in [fieldBackground, addressIcon, addressField, reloadButton] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addressBar.addSubview(v)
        }
        pageMenuButton.translatesAutoresizingMaskIntoConstraints = false
        fieldBackground.addSubview(pageMenuButton)
        pickerBanner.isHidden = true
        pickerBanner.onCancel = { [weak self] in self?.stopPicking() }

        let safe = view.safeAreaLayoutGuide

        // The bar itself has a FIXED height and only its bottom anchor moves —
        // that's what lets it translate as one unit above the keyboard. (An
        // earlier version also pinned its top to a fixed position, which meant
        // moving the bottom only squashed the bar's height instead of sliding
        // it — the visible controls, anchored to that fixed top, never moved
        // and stayed hidden under the keyboard.)
        // A static, non-animating backdrop of the same color sits behind it so
        // the bar's usual background still reaches the true screen bottom
        // (behind the home indicator) when the bar itself is at rest.
        addressBarBottom = addressBar.bottomAnchor.constraint(equalTo: safe.bottomAnchor)
        addressBarBottom.isActive = true

        NSLayoutConstraint.activate([
            addressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            addressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            addressBar.heightAnchor.constraint(equalToConstant: 50),

            addressBarBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            addressBarBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            addressBarBackdrop.topAnchor.constraint(equalTo: safe.bottomAnchor),
            addressBarBackdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            fieldBackground.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 10),
            fieldBackground.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -10),
            fieldBackground.topAnchor.constraint(equalTo: addressBar.topAnchor, constant: 7),
            fieldBackground.heightAnchor.constraint(equalToConstant: 36),

            addressIcon.leadingAnchor.constraint(equalTo: fieldBackground.leadingAnchor, constant: 4),
            addressIcon.centerYAnchor.constraint(equalTo: fieldBackground.centerYAnchor),
            addressIcon.widthAnchor.constraint(equalToConstant: 28),
            addressIcon.heightAnchor.constraint(equalToConstant: 28),

            addressField.leadingAnchor.constraint(equalTo: addressIcon.trailingAnchor, constant: 2),
            addressField.trailingAnchor.constraint(equalTo: reloadButton.leadingAnchor, constant: -4),
            addressField.topAnchor.constraint(equalTo: fieldBackground.topAnchor),
            addressField.bottomAnchor.constraint(equalTo: fieldBackground.bottomAnchor),

            reloadButton.trailingAnchor.constraint(equalTo: pageMenuButton.leadingAnchor, constant: -2),
            reloadButton.centerYAnchor.constraint(equalTo: fieldBackground.centerYAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: 32),
            reloadButton.heightAnchor.constraint(equalToConstant: 32),

            pageMenuButton.trailingAnchor.constraint(equalTo: fieldBackground.trailingAnchor, constant: -4),
            pageMenuButton.centerYAnchor.constraint(equalTo: fieldBackground.centerYAnchor),
            pageMenuButton.widthAnchor.constraint(equalToConstant: 32),
            pageMenuButton.heightAnchor.constraint(equalToConstant: 32),

            progressView.bottomAnchor.constraint(equalTo: addressBar.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),

            sidebar.topAnchor.constraint(equalTo: safe.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: addressBar.topAnchor),

            statusBarShield.topAnchor.constraint(equalTo: view.topAnchor),
            statusBarShield.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBarShield.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBarShield.bottomAnchor.constraint(equalTo: safe.topAnchor),

            // Page content runs all the way down behind the floating address
            // bar (it's inset at the bottom so nothing is hidden), like Safari.
            contentView.topAnchor.constraint(equalTo: safe.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            pickerBanner.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            pickerBanner.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            pickerBanner.bottomAnchor.constraint(equalTo: addressBar.topAnchor, constant: -10)
        ])

        NSLayoutConstraint.activate([
            pulloutHandle.topAnchor.constraint(equalTo: safe.topAnchor, constant: 70),
            pulloutHandle.widthAnchor.constraint(equalToConstant: 40),
            pulloutHandle.heightAnchor.constraint(equalToConstant: 44)
        ])
        pulloutLeading = pulloutHandle.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        pulloutTrailing = pulloutHandle.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        pulloutHandle.onActivate = { [weak self] in
            guard let self, self.sidebarState == .hidden else { return }
            self.setSidebarState(.minimal, animated: true)
        }
        pulloutHandle.menuProvider = { [weak self] in
            guard let self else { return nil }
            return self.tabMenu(for: self.selectedIndex)
        }

        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: TabSidebarView.minimalWidth)
        sidebarWidth.isActive = true

        sidebarLeading = sidebar.leadingAnchor.constraint(equalTo: safe.leadingAnchor)
        sidebarTrailing = sidebar.trailingAnchor.constraint(equalTo: safe.trailingAnchor)
        contentLeadingFromSidebar = contentView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor)
        contentLeadingFromSafe = contentView.leadingAnchor.constraint(equalTo: safe.leadingAnchor)
        contentTrailingFromSidebar = contentView.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor)
        contentTrailingFromSafe = contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor)

        applySidebarPosition()
        setSidebarState(Settings.shared.sidebarState, animated: false)
    }

    private func applySidebarPosition() {
        let position = Settings.shared.sidebarPosition
        guard position != lastAppliedSidebarPosition else { return }
        lastAppliedSidebarPosition = position

        NSLayoutConstraint.deactivate([sidebarLeading, sidebarTrailing, contentLeadingFromSidebar,
                                       contentLeadingFromSafe, contentTrailingFromSidebar, contentTrailingFromSafe,
                                       pulloutLeading, pulloutTrailing])
        if position == .leading {
            NSLayoutConstraint.activate([sidebarLeading, contentLeadingFromSidebar, contentTrailingFromSafe, pulloutLeading])
        } else {
            NSLayoutConstraint.activate([sidebarTrailing, contentTrailingFromSidebar, contentLeadingFromSafe, pulloutTrailing])
        }
        pulloutHandle.setEdge(position)
    }

    /// hidden: sidebar reserves no width at all (content gets the full screen);
    /// a small floating handle overlays the edge as the only way back in.
    /// minimal: a narrow column of every tab's icon.
    /// full: the same column with titles and close buttons.
    private func setSidebarState(_ state: SidebarState, animated: Bool) {
        sidebarState = state
        Settings.shared.sidebarState = state

        sidebar.isHidden = state == .hidden
        pulloutHandle.isHidden = state != .hidden
        sidebarWidth.constant = state == .full ? TabSidebarView.fullWidth : state == .minimal ? TabSidebarView.minimalWidth : 0
        if state != .hidden { sidebar.setMode(state == .full ? .full : .minimal) }
        refreshSidebar()

        if animated {
            UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseOut) { self.view.layoutIfNeeded() }
        }
    }

    /// The page-content area (tap or start of a scroll) collapses the sidebar
    /// back to hidden, whichever of the two visible states it was in.
    @objc private func handleImmersiveRequest(_ note: Notification) {
        guard let url = note.object as? URL else { return }
        presentImmersive(url: url)
    }

    @objc private func handleOpenURLRequest() {
        guard let pending = OpenURLRequest.pending else { return }
        OpenURLRequest.pending = nil
        openTab(url: pending.url, tor: pending.tor)
    }

    @objc private func handleNewTabRequest() {
        guard let tor = NewTabRequest.pendingTor else { return }
        NewTabRequest.pendingTor = nil
        openTab(url: nil, tor: tor)
    }

    /// Opens `url` as a normal tab (so it's right there with full chrome once
    /// the person exits) and immediately covers it with the chromeless viewer.
    private func presentImmersive(url: URL) {
        if presentedViewController != nil { dismiss(animated: false) }
        let tab = openTab(url: url, select: true)
        let vc = ImmersiveViewController(tab: tab)
        vc.onExit = { [weak self] in
            self?.dismiss(animated: false) { self?.showCurrentTab() }
        }
        present(vc, animated: false)
    }

    private func setupPageInteractionAutoHide() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handlePageTap))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        contentView.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePagePan(_:)))
        pan.cancelsTouchesInView = false
        pan.delegate = self
        contentView.addGestureRecognizer(pan)
    }

    @objc private func handlePageTap() {
        guard sidebarState != .hidden else { return }
        setSidebarState(.hidden, animated: true)
    }

    @objc private func handlePagePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            if sidebarState != .hidden { setSidebarState(.hidden, animated: true) }
        case .changed:
            updateSwipeNavigation(gesture)
        case .ended, .cancelled:
            finishSwipeNavigation(gesture)
        default:
            break
        }
    }

    /// Direction is locked in once the drag is clearly horizontal, and the
    /// current + destination page snapshots start tracking the finger — the
    /// same interactive feel as Safari's edge-swipe, just usable from
    /// anywhere on the page (see Tab.swift for why the edge-only WKWebView
    /// gesture is disabled instead of left running alongside this).
    private func updateSwipeNavigation(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: contentView)

        if swipeNav == nil {
            guard abs(translation.x) > 12, abs(translation.x) > abs(translation.y) * 1.5,
                  let tab = currentTab, !tab.isBlank else { return }
            let direction: SwipeNavDirection = translation.x > 0 ? .back : .forward
            if direction == .back {
                if tab.webView.canGoBack, let item = tab.webView.backForwardList.backItem {
                    beginSwipeNavigation(direction: .back, item: item, tab: tab)
                } else {
                    beginReturnToNewTabSwipe(tab: tab)
                }
            } else {
                guard tab.webView.canGoForward, let item = tab.webView.backForwardList.forwardItem else { return }
                beginSwipeNavigation(direction: .forward, item: item, tab: tab)
            }
        }
        guard let nav = swipeNav else { return }

        let width = max(contentView.bounds.width, 1)
        var dx = translation.x
        if abs(dx) > width {
            let over = abs(dx) - width
            dx = (dx < 0 ? -1 : 1) * (width + over * 0.2)
        }
        nav.outgoing.transform = CGAffineTransform(translationX: dx, y: 0)
        let incomingRest: CGFloat = nav.direction == .back ? -width : width
        nav.incoming.transform = CGAffineTransform(translationX: incomingRest + dx, y: 0)
    }

    private func beginSwipeNavigation(direction: SwipeNavDirection, item: WKBackForwardListItem, tab: Tab) {
        let bounds = contentView.bounds
        let container = UIView(frame: bounds)
        container.clipsToBounds = true
        container.isUserInteractionEnabled = false
        contentView.addSubview(container)

        let outgoing = tab.webView.snapshotView(afterScreenUpdates: false) ?? UIView(frame: bounds)
        outgoing.frame = bounds
        container.addSubview(outgoing)

        let incoming: UIView
        if let image = tab.historySnapshot(for: item.url) {
            let iv = UIImageView(image: image)
            iv.contentMode = .scaleAspectFill
            iv.clipsToBounds = true
            incoming = iv
        } else {
            incoming = UIView()
            incoming.backgroundColor = Theme.background
        }
        incoming.frame = bounds
        container.insertSubview(incoming, belowSubview: outgoing)

        swipeNav = SwipeNavState(direction: direction, item: item, tab: tab, outgoing: outgoing, incoming: incoming, container: container)
    }

    /// Swiping back past the start of a tab's history returns it to a blank
    /// New Tab Page rather than being a dead end.
    private func beginReturnToNewTabSwipe(tab: Tab) {
        let bounds = contentView.bounds
        let container = UIView(frame: bounds)
        container.clipsToBounds = true
        container.isUserInteractionEnabled = false
        contentView.addSubview(container)

        let outgoing = tab.webView.snapshotView(afterScreenUpdates: false) ?? UIView(frame: bounds)
        outgoing.frame = bounds
        container.addSubview(outgoing)

        let incoming = UIView(frame: bounds)
        incoming.backgroundColor = Theme.background
        let label = UILabel()
        label.text = "New Tab"
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = Theme.secondaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        incoming.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: incoming.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: incoming.centerYAnchor)
        ])
        container.insertSubview(incoming, belowSubview: outgoing)

        swipeNav = SwipeNavState(direction: .back, item: nil, tab: tab, outgoing: outgoing, incoming: incoming, container: container)
    }

    private func finishSwipeNavigation(_ gesture: UIPanGestureRecognizer) {
        guard let nav = swipeNav else { return }
        swipeNav = nil

        let width = max(contentView.bounds.width, 1)
        let translation = gesture.translation(in: contentView)
        let velocity = gesture.velocity(in: contentView)
        let progress = abs(translation.x) / width
        let commit = progress > 0.35 || abs(velocity.x) > 600

        let outgoingTarget: CGFloat = commit ? (nav.direction == .back ? width : -width) : 0
        let incomingRest: CGFloat = nav.direction == .back ? -width : width
        let incomingTarget: CGFloat = commit ? 0 : incomingRest

        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut], animations: {
            nav.outgoing.transform = CGAffineTransform(translationX: outgoingTarget, y: 0)
            nav.incoming.transform = CGAffineTransform(translationX: incomingTarget, y: 0)
        }, completion: { _ in
            nav.container.removeFromSuperview()
            guard commit else { return }
            if let item = nav.item {
                nav.tab.webView.go(to: item)
            } else {
                nav.tab.resetToBlank()
            }
        })
    }

    // MARK: Tabs

    /// True once this app process has done its first launch-time restore.
    /// A theme change rebuilds this controller mid-session, and that rebuild
    /// must always bring the tabs back, even with "close tabs on exit" on.
    private static var didInitialRestore = false

    private func restoreSession() {
        let isColdLaunch = !Self.didInitialRestore
        Self.didInitialRestore = true

        if isColdLaunch && Settings.shared.closeTabsOnExit {
            SessionStore.shared.clear()
            AppLog.shared.log("Starting fresh: 'close tabs on exit' is on", category: "app")
        } else if let session = SessionStore.shared.restore(), !session.tabs.isEmpty {
            for saved in session.tabs {
                let isTor = saved.tor ?? false
                let tab = makeTab(tor: isTor, id: saved.id)
                if !isTor, let state = saved.state, saved.url != nil {
                    tab.restore(interactionState: state)
                } else if let s = saved.url, let url = URL(string: s) {
                    tab.load(url)
                }
                tabs.append(tab)
            }
            selectedIndex = min(max(0, session.selected), tabs.count - 1)
            AppLog.shared.log("Restored \(tabs.count) tab(s)", category: "app")
        }
        if tabs.isEmpty {
            tabs.append(makeTab(tor: Settings.shared.torForNewTabs))
            selectedIndex = 0
        }
        showCurrentTab()
    }

    private var persistScheduled = false

    /// Saves shortly after any tab change, so tabs survive even if the app
    /// is killed without a clean trip through the background.
    private func schedulePersist() {
        guard !persistScheduled else { return }
        persistScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.persistScheduled = false
            self?.persist()
        }
    }

    private func makeTab(tor: Bool, id: UUID = UUID(), popupConfiguration: WKWebViewConfiguration? = nil) -> Tab {
        if tor { TorManager.shared.start() }
        let tab = Tab(isTor: tor, popupConfiguration: popupConfiguration, id: id)
        tab.delegate = self
        return tab
    }

    @discardableResult
    func openTab(url: URL?, tor: Bool? = nil, select: Bool = true) -> Tab {
        let isOnion = url?.host?.lowercased().hasSuffix(".onion") ?? false
        let tab = makeTab(tor: isOnion || (tor ?? Settings.shared.torForNewTabs))
        let insertAt = min(selectedIndex + 1, tabs.count)
        tabs.insert(tab, at: insertAt)
        if let url { tab.load(url) }
        schedulePersist()
        if select {
            selectedIndex = insertAt
            showCurrentTab()
            if url == nil { addressField.becomeFirstResponder() }
        } else {
            refreshSidebar()
        }
        return tab
    }

    private func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        stopPicking()
        selectedIndex = index
        showCurrentTab()
    }

    private func close(tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        if pickingTab === tab { stopPicking() }
        tab.webView.stopLoading()
        tab.webView.removeFromSuperview()
        tabs.remove(at: index)

        if tabs.isEmpty {
            tabs.append(makeTab(tor: Settings.shared.torForNewTabs))
            selectedIndex = 0
        } else if index < selectedIndex || selectedIndex >= tabs.count {
            selectedIndex = max(0, selectedIndex - 1)
        }
        showCurrentTab()

        if !tab.isTor && Settings.shared.cookieCleanup == .onTabClose {
            CookieGuard.shared.cleanUp(activeHosts: tabs.compactMap { $0.isTor ? nil : $0.host })
        }
        persist()
    }

    private func showCurrentTab() {
        for sub in contentView.subviews where sub is WKWebView { sub.removeFromSuperview() }
        detectedManifest = nil
        guard let tab = currentTab else { return }
        tab.webView.frame = contentView.bounds
        tab.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.insertSubview(tab.webView, at: 0)
        tab.applyContentRules(for: tab.host)
        updateChrome()
    }

    func navigate(to url: URL) {
        guard let tab = currentTab else { openTab(url: url); return }
        tab.load(url)
        updateChrome()
    }

    func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("://"), let url = URL(string: text), url.host != nil { return url }
        let looksLikeHost = !text.contains(" ") && (text.contains(".") || text.hasPrefix("localhost"))
        if looksLikeHost, let url = URL(string: "https://" + text), url.host != nil { return url }
        return Settings.shared.searchURL(for: text)
    }

    func persist() {
        SessionStore.shared.save(tabs: tabs.filter { !$0.isPopup || $0.url != nil }, selected: currentTab)
        BlockStats.shared.flush()
    }

    func appDidEnterBackground() {
        persist()
        if Settings.shared.cookieCleanup == .onBackground {
            CookieGuard.shared.cleanUp(activeHosts: tabs.compactMap { $0.isTor ? nil : $0.host })
        }
    }

    // MARK: Chrome updates

    @objc private func updateChrome() {
        guard isViewLoaded, let tab = currentTab else { return }

        if !addressField.isFirstResponder {
            addressField.text = tab.url.map { DomainUtil.normalize($0.host ?? $0.absoluteString) } ?? ""
        }
        if tab.isTor {
            addressIcon.setImage(OnionIcon.image(pointSize: 16), for: .normal)
            addressIcon.tintColor = Theme.tor
        } else if tab.url?.scheme == "http" {
            addressIcon.setImage(Theme.icon("exclamationmark.triangle"), for: .normal)
            addressIcon.tintColor = .systemOrange
        } else if tab.url != nil {
            addressIcon.setImage(Theme.icon("lock.fill"), for: .normal)
            addressIcon.tintColor = Theme.secondaryText
        } else {
            addressIcon.setImage(Theme.icon("magnifyingglass"), for: .normal)
            addressIcon.tintColor = Theme.secondaryText
        }
        if addressField.isFirstResponder {
            // While typing, this slot clears the field (stop-loading glyph).
            reloadButton.setImage(Theme.icon("xmark"), for: .normal)
            reloadButton.isHidden = (addressField.text ?? "").isEmpty
            reloadButton.accessibilityLabel = "Clear"
        } else {
            reloadButton.setImage(Theme.icon(tab.webView.isLoading ? "xmark" : "arrow.clockwise"), for: .normal)
            reloadButton.isHidden = tab.url == nil
            reloadButton.accessibilityLabel = tab.webView.isLoading ? "Stop" : "Reload"
        }
        updateAddressBarTint(for: tab)
        applyBottomInsets()

        let progress = Float(tab.webView.estimatedProgress)
        progressView.setProgress(progress, animated: progress > progressView.progress)
        progressView.isHidden = !tab.webView.isLoading

        ntp.view.isHidden = !tab.isBlank
        if !ntp.view.isHidden { ntp.reload() }

        torOverlay.isHidden = !tab.isWaitingForTor
        torOverlay.update(state: TorManager.shared.state)

        applySidebarPosition()
        refreshSidebar()
    }

    private func refreshSidebar() {
        sidebar.update(items: tabs.enumerated().map { index, tab in
            SidebarItem(icon: tab.icon, title: tab.title, isTor: tab.isTor,
                        isSelected: index == selectedIndex, isLoading: tab.webView.isLoading || tab.isWaitingForTor)
        })
        if let tab = currentTab {
            pulloutHandle.configure(icon: tab.icon, isTor: tab.isTor, isLoading: tab.webView.isLoading || tab.isWaitingForTor)
        }
    }

    @objc private func rulesUpdated() {
        for tab in tabs { tab.applyContentRules(for: tab.host, force: true) }
    }

    @objc private func elementRulesChanged() {
        for tab in tabs { tab.reinstallScripts() }
    }

    @objc private func settingsChanged() {
        applySidebarPosition()
        for tab in tabs { tab.reinstallScripts() }
    }

    /// The address bar is pinned to the bottom of the screen, so without this
    /// the keyboard would simply cover it while typing. Moves it — and
    /// everything anchored above it — up to sit right above the keyboard.
    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        guard let userInfo = note.userInfo,
              let endFrameValue = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let endFrameInView = view.convert(endFrameValue.cgRectValue, from: nil)
        let overlap = max(0, view.bounds.maxY - endFrameInView.minY)
        let bottomInset = view.safeAreaInsets.bottom
        let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? UIView.AnimationCurve.easeInOut.rawValue
        let curve = UIView.AnimationCurve(rawValue: curveRaw) ?? .easeInOut

        addressBarBottom.constant = overlap > 0 ? -(overlap - bottomInset) : 0
        let animator = UIViewPropertyAnimator(duration: duration, curve: curve) { [weak self] in
            self?.view.layoutIfNeeded()
        }
        animator.startAnimation()
    }

    @objc private func torStateChanged() {
        if TorManager.shared.isReady {
            for tab in tabs where tab.isTor { tab.torBecameReady() }
        }
        updateChrome()
    }

    // MARK: Address bar actions

    private func reloadOrStop() {
        if addressField.isFirstResponder {
            addressField.text = ""
            updateChrome()
            return
        }
        guard let wv = currentTab?.webView else { return }
        if wv.isLoading { wv.stopLoading() } else { wv.reload() }
    }

    /// Switches the current tab into / out of Tor by recreating it with the
    /// other data store (a web view's network stack can't be swapped live).
    private func toggleTor() {
        guard let old = currentTab, let index = tabs.firstIndex(where: { $0 === old }) else { return }
        let url = old.url
        let tab = makeTab(tor: !old.isTor)
        old.webView.stopLoading()
        old.webView.removeFromSuperview()
        tabs[index] = tab
        if let url { tab.load(url) }
        showCurrentTab()
        showToast(tab.isTor ? "This tab now uses Tor" : "Tor off for this tab")
    }

    /// A tab that's stuck waiting on Tor is never a dead end — this swaps it
    /// for a plain non-Tor tab loading the same pending URL.
    private func cancelTorWaitOnCurrentTab() {
        guard let old = currentTab, old.isWaitingForTor, let index = tabs.firstIndex(where: { $0 === old }) else { return }
        let url = old.url
        let tab = makeTab(tor: false)
        old.webView.stopLoading()
        old.webView.removeFromSuperview()
        tabs[index] = tab
        if let url { tab.load(url) }
        showCurrentTab()
        showToast("Loading without Tor")
    }

    /// Actions for the whole page, reached from the ⋯ button in the address bar.
    /// Favorite / trust / hide-element / pause-blocking live on the tab itself
    /// (long-press the tab in the sidebar) instead of here.
    private func pageSettingsElements() -> [UIMenuElement] {
        guard let tab = currentTab else { return [] }
        var pageActions: [UIMenuElement] = []

        pageActions.append(UIAction(title: tab.isTor ? "Turn Off Tor for This Tab" : "Use Tor for This Tab",
                                    image: OnionIcon.image(pointSize: 18)) { [weak self] _ in self?.toggleTor() })
        if tab.isTor && TorManager.shared.isReady {
            pageActions.append(UIAction(title: "New Tor Identity", image: Theme.icon("arrow.triangle.2.circlepath")) { _ in
                TorManager.shared.newIdentity { ok in
                    if ok { tab.webView.reload() }
                }
            })
        }
        if let url = tab.webView.url {
            pageActions.append(UIAction(title: "Share", image: Theme.icon("square.and.arrow.up")) { [weak self] _ in
                self?.present(UIActivityViewController(activityItems: [url], applicationActivities: nil), animated: true)
            })
        }
        if let manifest = detectedManifest, tab.webView.url != nil, !tab.isTor,
           manifest.startURL.host == tab.webView.url?.host {
            if PWAStore.shared.isInstalled(startURL: manifest.startURL) {
                pageActions.append(UIAction(title: "App Installed", image: Theme.icon("checkmark.circle"), attributes: .disabled) { _ in })
            } else {
                pageActions.append(UIAction(title: "Install as App", image: Theme.icon("square.and.arrow.down.on.square")) { [weak self] _ in
                    self?.installPWA(manifest)
                })
            }
        }

        let appActions: [UIMenuElement] = [
            UIAction(title: "Settings", image: Theme.icon("gearshape")) { [weak self] _ in
                let settings = SettingsViewController()
                settings.onOpenFavorite = { url in self?.navigate(to: url) }
                self?.navigationController?.pushViewController(settings, animated: true)
            }
        ]
        return [UIMenu(options: .displayInline, children: pageActions), UIMenu(options: .displayInline, children: appActions)]
    }

    /// Actions for one specific tab, reached by long-pressing it in the sidebar.
    private func tabMenu(for index: Int) -> UIMenu? {
        guard tabs.indices.contains(index) else { return nil }
        let tab = tabs[index]
        var actions: [UIMenuElement] = []

        if let url = tab.webView.url {
            let isFav = FavoritesStore.shared.isFavorite(url: url)
            actions.append(UIAction(title: isFav ? "Remove Favorite" : "Add Favorite",
                                    image: Theme.icon(isFav ? "star.fill" : "star")) { [weak self] _ in
                FavoritesStore.shared.toggle(url: url, title: tab.webView.title ?? url.host ?? url.absoluteString)
                self?.updateChrome()
            })

            if let host = url.host {
                let normalized = WhitelistStore.normalize(host)
                let trusted = WhitelistStore.shared.isWhitelisted(host: normalized)
                actions.append(UIAction(title: trusted ? "Untrust Site" : "Trust Site",
                                        image: Theme.icon(trusted ? "checkmark.shield.fill" : "checkmark.shield")) { [weak self] _ in
                    if trusted { WhitelistStore.shared.remove(host: normalized) } else { WhitelistStore.shared.add(host: normalized) }
                    self?.showToast(trusted ? "\(normalized) can no longer redirect or open pop-ups" : "Trusted \(normalized) with redirects and pop-ups")
                    self?.updateChrome()
                })

                let base = DomainUtil.baseDomain(host)
                let paused = ContentBlocker.shared.paused.contains(host: host)
                actions.append(UIAction(title: paused ? "Resume Blocking on \(base)" : "Pause Blocking on \(base)",
                                        image: Theme.icon(paused ? "play.circle" : "pause.circle")) { [weak self] _ in
                    ContentBlocker.shared.paused.toggle(host: host)
                    tab.applyContentRules(for: host, force: true)
                    tab.webView.reload()
                    self?.updateChrome()
                })
            }

            actions.append(UIAction(title: "Hide Element…", image: Theme.icon("eye.slash")) { [weak self] _ in
                self?.select(index: index)
                self?.startPicking()
            })
        }

        actions.append(UIAction(title: "Close Tab", image: Theme.icon("xmark"), attributes: .destructive) { [weak self] _ in
            self?.close(tab: tab)
        })
        if tabs.count > 1 {
            actions.append(UIAction(title: "Close Other Tabs", image: Theme.icon("xmark.square")) { [weak self] _ in
                for other in self?.tabs ?? [] where other !== tab { self?.close(tab: other) }
            })
        }
        return UIMenu(children: actions)
    }

    // MARK: Element picker

    private func startPicking() {
        guard let tab = currentTab, tab.webView.url != nil else { return }
        pickingTab = tab
        tab.runInClientWorld("window.__undirectPicker && window.__undirectPicker.start()")
        pickerBanner.isHidden = false
    }

    private func stopPicking() {
        pickingTab?.runInClientWorld("window.__undirectPicker && window.__undirectPicker.stop()")
        pickingTab = nil
        pickerBanner.isHidden = true
    }

    private func presentPickSheet(selector: String, label: String) {
        guard let tab = pickingTab else { return }
        let sheet = UIAlertController(title: "Hide this element?", message: label, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Hide", style: .destructive) { [weak self] _ in
            guard let host = tab.webView.url?.host else { return }
            tab.runInClientWorld("window.__undirectPicker && window.__undirectPicker.hide()")
            self?.pickingTab = nil
            self?.pickerBanner.isHidden = true
            ElementHideStore.shared.add(selector: selector, host: host)
            self?.showToast("Hidden on \(DomainUtil.baseDomain(host))")
        })
        sheet.addAction(UIAlertAction(title: "Select larger area", style: .default) { [weak self] _ in
            tab.callInClientWorld("return window.__undirectPicker ? window.__undirectPicker.parent() : null;") { value in
                guard let dict = value as? [String: Any], let sel = dict["selector"] as? String,
                      let lbl = dict["label"] as? String else { return }
                self?.presentPickSheet(selector: sel, label: lbl)
            }
        })
        sheet.addAction(UIAlertAction(title: "Pick something else", style: .default))
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.stopPicking() })
        present(sheet, animated: true)
    }

    // MARK: Toast

    // MARK: PWA

    func installPWA(_ manifest: WebAppManifest) {
        let seed = abs(PWAStore.identifier(for: manifest.startURL).hashValue)
        fetchBestIcon(from: manifest.iconURLs) { [weak self] pngData in
            let pwa = InstalledPWA(
                id: PWAStore.identifier(for: manifest.startURL),
                name: manifest.name,
                startURL: manifest.startURL.absoluteString,
                scope: manifest.scope.absoluteString,
                themeColorHex: manifest.themeColorHex,
                backgroundColorHex: manifest.backgroundColorHex,
                iconPNGBase64: pngData?.base64EncodedString(),
                iconSeed: seed
            )
            PWAStore.shared.install(pwa)
            self?.showToast("\(manifest.name) installed")
        }
    }

    /// Fetches the largest usable manifest icon over a plain ephemeral session
    /// (never for Tor — but PWAs are non-Tor by construction here). Falls back
    /// to a generated icon if none load.
    private func fetchBestIcon(from urls: [URL], completion: @escaping (Data?) -> Void) {
        var remaining = urls
        func tryNext() {
            guard !remaining.isEmpty else { completion(nil); return }
            let url = remaining.removeFirst()
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            URLSession(configuration: config).dataTask(with: url) { data, response, _ in
                if let data, (response as? HTTPURLResponse)?.statusCode ?? 0 < 400, UIImage(data: data) != nil {
                    // Re-encode to PNG at a reasonable size to bound storage.
                    if let image = UIImage(data: data) {
                        let target = CGSize(width: 180, height: 180)
                        let resized = UIGraphicsImageRenderer(size: target).image { _ in
                            image.draw(in: CGRect(origin: .zero, size: target))
                        }
                        DispatchQueue.main.async { completion(resized.pngData()) }
                        return
                    }
                }
                DispatchQueue.main.async { tryNext() }
            }.resume()
        }
        tryNext()
    }

    func launchPWA(_ pwa: InstalledPWA) {
        guard let url = pwa.startURLValue else { return }
        let vc = StandalonePWAViewController(pwa: pwa)
        vc.modalPresentationStyle = .fullScreen
        present(vc, animated: true)
        _ = url
    }

    private func showToast(_ message: String, action: (() -> Void)? = nil) {
        let label = PaddedLabel()
        if let action {
            label.isUserInteractionEnabled = true
            label.addGestureRecognizer(ToastTapRecognizer(action: {
                action()
                label.removeFromSuperview()
            }))
        }
        label.text = message
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        label.layer.cornerRadius = Theme.cornerRadius
        label.clipsToBounds = true
        label.numberOfLines = 0
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: addressBar.topAnchor, constant: -12)
        ])
        UIView.animate(withDuration: 0.2, animations: { label.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.25, delay: action == nil ? 1.6 : 3.2, options: [.allowUserInteraction], animations: { label.alpha = 0 }) { _ in
                label.removeFromSuperview()
            }
        }
    }
}

// MARK: - Address field

extension BrowserContainerViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

extension BrowserContainerViewController: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        textField.text = currentTab?.webView.url?.absoluteString ?? ""
        DispatchQueue.main.async { textField.selectAll(nil) }
        updateChrome()
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        DispatchQueue.main.async { [weak self] in self?.updateChrome() }
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        updateChrome()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if let url = url(from: textField.text ?? "") { navigate(to: url) }
        textField.resignFirstResponder()
        return true
    }
}

// MARK: - Sidebar

extension BrowserContainerViewController: TabSidebarDelegate {
    func sidebarDidSelect(index: Int) {
        select(index: index)
        if sidebarState == .full && traitCollection.horizontalSizeClass == .compact {
            setSidebarState(.minimal, animated: true)
        }
    }

    func sidebarDidClose(index: Int) {
        guard tabs.indices.contains(index) else { return }
        close(tab: tabs[index])
    }

    func sidebarDidRequestNewTab(tor: Bool?) {
        openTab(url: nil, tor: tor)
    }

    func sidebarDidRequestToggleFull() {
        guard sidebarState != .hidden else { return }
        setSidebarState(sidebarState == .full ? .minimal : .full, animated: true)
    }

    func sidebarMenu(for index: Int) -> UIMenu? {
        tabMenu(for: index)
    }
}

// MARK: - Tab delegate

extension BrowserContainerViewController: TabDelegate {
    func tabDidChange(_ tab: Tab) {
        if tab === currentTab { updateChrome() } else { refreshSidebar() }
        schedulePersist()
    }

    func tab(_ tab: Tab, toast message: String) {
        if tab === currentTab { showToast(message) }
    }

    func tab(_ tab: Tab, openInNewTab url: URL) {
        openTab(url: url, tor: tab.isTor)
    }

    func tab(_ tab: Tab, openInBackgroundTab url: URL) {
        openTab(url: url, tor: tab.isTor, select: false)
        if tab === currentTab { showToast("Opened in background") }
    }

    func tab(_ tab: Tab, openInTorTab url: URL) {
        openTab(url: url, tor: true)
        showToast("Opened in a Tor tab")
    }

    func tab(_ tab: Tab, blockedPopupTo url: URL) {
        guard tab === currentTab else { return }
        let host = DomainUtil.baseDomain(url.host ?? "")
        showToast("Blocked pop-up to \(host) · Tap to open") { [weak self] in
            self?.openTab(url: url, tor: tab.isTor)
        }
    }

    func tab(_ tab: Tab, foundInstallableManifest manifest: WebAppManifest) {
        guard tab === currentTab, !tab.isTor else { return }
        detectedManifest = manifest
        // Only nudge once per app, and never if already installed.
        guard !PWAStore.shared.isInstalled(startURL: manifest.startURL),
              !shownInstallPromptFor.contains(PWAStore.identifier(for: manifest.startURL)) else { return }
        shownInstallPromptFor.insert(PWAStore.identifier(for: manifest.startURL))
        showToast("Install \(manifest.name) as an app? · Tap to add") { [weak self] in
            self?.installPWA(manifest)
        }
    }

    func tab(_ tab: Tab, share url: URL) {
        present(UIActivityViewController(activityItems: [url], applicationActivities: nil), animated: true)
    }

    func tab(_ tab: Tab, createPopupWith configuration: WKWebViewConfiguration, url: URL) -> WKWebView? {
        let popup = makeTab(tor: tab.isTor, popupConfiguration: configuration)
        let insertAt = min(selectedIndex + 1, tabs.count)
        tabs.insert(popup, at: insertAt)
        selectedIndex = insertAt
        showCurrentTab()
        return popup.webView
    }

    func tabDidRequestClose(_ tab: Tab) {
        close(tab: tab)
    }

    func tab(_ tab: Tab, didPick selector: String, label: String) {
        guard tab === pickingTab else { return }
        presentPickSheet(selector: selector, label: label)
    }

    func presenter(for tab: Tab) -> UIViewController? {
        tab === currentTab ? self : nil
    }
}

// MARK: - Small views

final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    override func layoutSubviews() {
        super.layoutSubviews()
        Theme.applyBlockShadow(to: self)
    }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
    }
}

final class TorConnectingView: UIView {
    private let label = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let icon = UIImageView(image: OnionIcon.image(pointSize: 44))
    private let cancelButton = UIButton(type: .system)
    var onCancel: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.background
        icon.tintColor = Theme.tor
        icon.contentMode = .scaleAspectFit
        label.textColor = Theme.text
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textAlignment = .center
        label.numberOfLines = 0
        progress.progressTintColor = Theme.tor
        var buttonConfig = UIButton.Configuration.plain()
        buttonConfig.title = "Cancel — load without Tor"
        cancelButton.configuration = buttonConfig
        cancelButton.tintColor = Theme.secondaryText
        cancelButton.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [icon, label, progress, cancelButton])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.heightAnchor.constraint(equalToConstant: 44),
            icon.widthAnchor.constraint(equalToConstant: 44),
            progress.widthAnchor.constraint(equalToConstant: 180),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24)
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(state: TorManager.State) {
        switch state {
        case .starting(let p):
            label.text = "Connecting to Tor…"
            progress.setProgress(Float(p) / 100, animated: true)
            progress.isHidden = false
        case .failed(let why):
            label.text = "Tor couldn't connect (\(why))."
            progress.isHidden = true
        default:
            label.text = "Connecting to Tor…"
            progress.isHidden = false
        }
    }
}

/// The only visible sidebar control in the "hidden" state: a small handle
/// docked to whichever edge the tab bar belongs on, showing the current tab's
/// icon. Tapping or swiping it away from the edge reveals the tab bar; the
/// tab bar itself reserves no width while this is showing, so the page gets
/// the full screen.
final class PulloutHandleView: UIView {
    var onActivate: (() -> Void)?
    var menuProvider: (() -> UIMenu?)?

    private let iconView = UIImageView()
    private let torBadge = UIImageView(image: OnionIcon.image(pointSize: 12))
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let swipeGesture = UISwipeGestureRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.bar
        layer.cornerRadius = Theme.cornerRadius

        iconView.contentMode = .scaleAspectFill
        iconView.layer.cornerRadius = Theme.smallCornerRadius
        iconView.clipsToBounds = true
        torBadge.tintColor = Theme.tor
        torBadge.contentMode = .scaleAspectFit
        torBadge.backgroundColor = Theme.bar
        torBadge.layer.cornerRadius = 3
        spinner.color = Theme.secondaryText
        spinner.hidesWhenStopped = true

        for v in [iconView, torBadge, spinner] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),
            torBadge.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 3),
            torBadge.bottomAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 3),
            torBadge.widthAnchor.constraint(equalToConstant: 14),
            torBadge.heightAnchor.constraint(equalToConstant: 14),
            spinner.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: iconView.centerYAnchor)
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        swipeGesture.addTarget(self, action: #selector(handleTap))
        addGestureRecognizer(swipeGesture)
        addInteraction(UIContextMenuInteraction(delegate: self))
        accessibilityLabel = "Show tabs"
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func handleTap() { onActivate?() }

    func setEdge(_ position: SidebarPosition) {
        swipeGesture.direction = position == .leading ? .right : .left
    }

    func configure(icon: UIImage, isTor: Bool, isLoading: Bool) {
        iconView.image = icon
        torBadge.isHidden = !isTor
        iconView.alpha = isLoading ? 0.35 : 1
        if isLoading { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        Theme.applyBlockShadow(to: self)
    }
}

extension PulloutHandleView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in self?.menuProvider?() }
    }
}

final class PickerBanner: UIView {
    var onCancel: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.55, green: 0.18, blue: 0.32, alpha: 0.95)
        layer.cornerRadius = Theme.cornerRadius
        let label = UILabel()
        label.text = "Tap the element you want to hide"
        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .medium)
        let button = UIButton(type: .system)
        button.setTitle("Done", for: .normal)
        button.tintColor = .white
        button.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}


/// Tap recognizer that carries its own closure (for tappable toasts).
final class ToastTapRecognizer: UITapGestureRecognizer {
    private let handler: () -> Void
    init(action: @escaping () -> Void) {
        handler = action
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(fire))
    }
    @objc private func fire() { handler() }
}
