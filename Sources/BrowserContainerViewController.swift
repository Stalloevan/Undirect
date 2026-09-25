import UIKit
import WebKit

final class BrowserContainerViewController: UIViewController {

    private(set) var tabs: [Tab] = []
    private var selectedIndex = 0
    private var currentTab: Tab? { tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil }

    // Chrome — address bar lives at the bottom; back/forward are swipe-only
    // (WKWebView's own edge-swipe gesture, always on).
    private let addressBar = UIView()
    private let addressField = UITextField()
    private let addressIcon = UIImageView()
    private let reloadButton = UIButton(type: .system)
    private lazy var pageMenuButton = UIButton(type: .system)
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let sidebar = TabSidebarView()
    private var sidebarWidth: NSLayoutConstraint!
    private let contentView = UIView()
    private let ntp = NewTabPageViewController()
    private let torOverlay = TorConnectingView()
    private let pickerBanner = PickerBanner()

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
        ntp.onCustomize = { [weak self] in
            self?.navigationController?.pushViewController(NTPLayoutViewController(), animated: true)
        }

        torOverlay.frame = contentView.bounds
        torOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(torOverlay)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(rulesUpdated), name: ContentBlocker.didUpdate, object: nil)
        nc.addObserver(self, selector: #selector(rulesUpdated), name: DomainSetStore.didChange, object: nil)
        nc.addObserver(self, selector: #selector(torStateChanged), name: TorManager.stateDidChange, object: nil)
        nc.addObserver(self, selector: #selector(elementRulesChanged), name: ElementHideStore.didChange, object: nil)
        nc.addObserver(self, selector: #selector(updateChrome), name: FavoritesStore.didChange, object: nil)
        nc.addObserver(self, selector: #selector(settingsChanged), name: Settings.didChange, object: nil)
        nc.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)

        restoreSession()
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

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: Layout

    private func buildChrome() {
        addressBar.backgroundColor = Theme.bar
        let fieldBackground = UIView()
        fieldBackground.backgroundColor = Theme.field
        fieldBackground.layer.cornerRadius = 11

        addressIcon.tintColor = Theme.secondaryText
        addressIcon.contentMode = .scaleAspectFit

        addressField.textColor = Theme.text
        addressField.font = .systemFont(ofSize: 15)
        addressField.attributedPlaceholder = NSAttributedString(string: "Search or enter address",
                                                                attributes: [.foregroundColor: Theme.secondaryText])
        addressField.keyboardType = .webSearch
        addressField.returnKeyType = .go
        addressField.autocapitalizationType = .none
        addressField.autocorrectionType = .no
        addressField.clearButtonMode = .whileEditing
        addressField.keyboardAppearance = .dark
        addressField.delegate = self

        reloadButton.tintColor = Theme.secondaryText
        reloadButton.addAction(UIAction { [weak self] _ in self?.reloadOrStop() }, for: .touchUpInside)

        pageMenuButton.tintColor = Theme.text
        pageMenuButton.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        pageMenuButton.showsMenuAsPrimaryAction = true
        pageMenuButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.pageSettingsElements() ?? [])
        }])
        pageMenuButton.accessibilityLabel = "Page settings"

        progressView.progressTintColor = Theme.accent
        progressView.trackTintColor = .clear

        sidebar.delegate = self

        contentView.backgroundColor = Theme.background
        contentView.clipsToBounds = true

        for v in [contentView, sidebar, addressBar, progressView, pickerBanner] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        for v in [fieldBackground, addressIcon, addressField, reloadButton, pageMenuButton] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addressBar.addSubview(v)
        }
        pickerBanner.isHidden = true
        pickerBanner.onCancel = { [weak self] in self?.stopPicking() }

        let safe = view.safeAreaLayoutGuide

        addressBarBottom = addressBar.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        addressBarBottom.isActive = true

        NSLayoutConstraint.activate([
            addressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            addressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            addressBar.topAnchor.constraint(equalTo: safe.bottomAnchor, constant: -50),

            fieldBackground.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 10),
            fieldBackground.trailingAnchor.constraint(equalTo: pageMenuButton.leadingAnchor, constant: -6),
            fieldBackground.topAnchor.constraint(equalTo: addressBar.topAnchor, constant: 7),
            fieldBackground.heightAnchor.constraint(equalToConstant: 36),

            addressIcon.leadingAnchor.constraint(equalTo: fieldBackground.leadingAnchor, constant: 10),
            addressIcon.centerYAnchor.constraint(equalTo: fieldBackground.centerYAnchor),
            addressIcon.widthAnchor.constraint(equalToConstant: 16),
            addressIcon.heightAnchor.constraint(equalToConstant: 16),

            addressField.leadingAnchor.constraint(equalTo: addressIcon.trailingAnchor, constant: 8),
            addressField.trailingAnchor.constraint(equalTo: reloadButton.leadingAnchor, constant: -4),
            addressField.topAnchor.constraint(equalTo: fieldBackground.topAnchor),
            addressField.bottomAnchor.constraint(equalTo: fieldBackground.bottomAnchor),

            reloadButton.trailingAnchor.constraint(equalTo: fieldBackground.trailingAnchor, constant: -4),
            reloadButton.centerYAnchor.constraint(equalTo: fieldBackground.centerYAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: 32),
            reloadButton.heightAnchor.constraint(equalToConstant: 32),

            pageMenuButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -10),
            pageMenuButton.centerYAnchor.constraint(equalTo: fieldBackground.centerYAnchor),
            pageMenuButton.widthAnchor.constraint(equalToConstant: 32),
            pageMenuButton.heightAnchor.constraint(equalToConstant: 32),

            progressView.bottomAnchor.constraint(equalTo: addressBar.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),

            sidebar.topAnchor.constraint(equalTo: safe.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: addressBar.topAnchor),

            contentView.topAnchor.constraint(equalTo: view.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: addressBar.topAnchor),

            pickerBanner.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            pickerBanner.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            pickerBanner.bottomAnchor.constraint(equalTo: addressBar.topAnchor, constant: -10)
        ])

        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: TabSidebarView.collapsedWidth)
        sidebarWidth.isActive = true

        sidebarLeading = sidebar.leadingAnchor.constraint(equalTo: safe.leadingAnchor)
        sidebarTrailing = sidebar.trailingAnchor.constraint(equalTo: safe.trailingAnchor)
        contentLeadingFromSidebar = contentView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor)
        contentLeadingFromSafe = contentView.leadingAnchor.constraint(equalTo: safe.leadingAnchor)
        contentTrailingFromSidebar = contentView.trailingAnchor.constraint(equalTo: sidebar.leadingAnchor)
        contentTrailingFromSafe = contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor)

        setSidebarExpanded(Settings.shared.sidebarExpanded, animated: false)
        applySidebarPosition()
    }

    private func applySidebarPosition() {
        let position = Settings.shared.sidebarPosition
        guard position != lastAppliedSidebarPosition else { return }
        lastAppliedSidebarPosition = position

        NSLayoutConstraint.deactivate([sidebarLeading, sidebarTrailing, contentLeadingFromSidebar,
                                       contentLeadingFromSafe, contentTrailingFromSidebar, contentTrailingFromSafe])
        if position == .leading {
            NSLayoutConstraint.activate([sidebarLeading, contentLeadingFromSidebar, contentTrailingFromSafe])
        } else {
            NSLayoutConstraint.activate([sidebarTrailing, contentTrailingFromSidebar, contentLeadingFromSafe])
        }
    }

    private func setSidebarExpanded(_ expanded: Bool, animated: Bool) {
        Settings.shared.sidebarExpanded = expanded
        sidebarWidth.constant = expanded ? TabSidebarView.expandedWidth : TabSidebarView.collapsedWidth
        sidebar.setExpanded(expanded)
        refreshSidebar()
        if animated {
            UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseOut) { self.view.layoutIfNeeded() }
        }
    }

    // MARK: Tabs

    private func restoreSession() {
        if let session = SessionStore.shared.restore(), !session.tabs.isEmpty {
            for saved in session.tabs {
                let tab = makeTab(tor: false, id: saved.id)
                if let state = saved.state, saved.url != nil {
                    tab.restore(interactionState: state)
                } else if let s = saved.url, let url = URL(string: s) {
                    tab.load(url)
                }
                tabs.append(tab)
            }
            selectedIndex = min(max(0, session.selected), tabs.count - 1)
        } else {
            tabs.append(makeTab(tor: Settings.shared.torForNewTabs))
            selectedIndex = 0
        }
        showCurrentTab()
    }

    private func makeTab(tor: Bool, id: UUID = UUID(), popupConfiguration: WKWebViewConfiguration? = nil) -> Tab {
        if tor { TorManager.shared.start() }
        let tab = Tab(isTor: tor, popupConfiguration: popupConfiguration, id: id)
        tab.delegate = self
        return tab
    }

    @discardableResult
    func openTab(url: URL?, tor: Bool? = nil, select: Bool = true) -> Tab {
        let tab = makeTab(tor: tor ?? Settings.shared.torForNewTabs)
        let insertAt = min(selectedIndex + 1, tabs.count)
        tabs.insert(tab, at: insertAt)
        if let url { tab.load(url) }
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

    private func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("://"), let url = URL(string: text), url.host != nil { return url }
        let looksLikeHost = !text.contains(" ") && (text.contains(".") || text.hasPrefix("localhost"))
        if looksLikeHost, let url = URL(string: "https://" + text), url.host != nil { return url }
        var comps = URLComponents(string: "https://duckduckgo.com/")!
        comps.queryItems = [URLQueryItem(name: "q", value: text)]
        return comps.url
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
            addressIcon.image = OnionIcon.image(pointSize: 16)
            addressIcon.tintColor = Theme.tor
        } else if tab.url?.scheme == "http" {
            addressIcon.image = UIImage(systemName: "exclamationmark.triangle")
            addressIcon.tintColor = .systemOrange
        } else if tab.url != nil {
            addressIcon.image = UIImage(systemName: "lock.fill")
            addressIcon.tintColor = Theme.secondaryText
        } else {
            addressIcon.image = UIImage(systemName: "magnifyingglass")
            addressIcon.tintColor = Theme.secondaryText
        }
        reloadButton.setImage(UIImage(systemName: tab.webView.isLoading ? "xmark" : "arrow.clockwise"), for: .normal)
        reloadButton.isHidden = tab.url == nil

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
        let curveRaw = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? UIView.AnimationCurve.easeInOut.rawValue
        let curve = UIView.AnimationCurve(rawValue: Int(curveRaw)) ?? .easeInOut

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

    /// Actions for the whole page, reached from the ⋯ button in the address bar.
    /// Favorite / trust / hide-element / pause-blocking live on the tab itself
    /// (long-press the tab in the sidebar) instead of here.
    private func pageSettingsElements() -> [UIMenuElement] {
        guard let tab = currentTab else { return [] }
        var pageActions: [UIMenuElement] = []

        pageActions.append(UIAction(title: tab.isTor ? "Turn Off Tor for This Tab" : "Use Tor for This Tab",
                                    image: OnionIcon.image(pointSize: 18)) { [weak self] _ in self?.toggleTor() })
        if tab.isTor && TorManager.shared.isReady {
            pageActions.append(UIAction(title: "New Tor Identity", image: UIImage(systemName: "arrow.triangle.2.circlepath")) { _ in
                TorManager.shared.newIdentity { ok in
                    if ok { tab.webView.reload() }
                }
            })
        }
        if let url = tab.webView.url {
            pageActions.append(UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                self?.present(UIActivityViewController(activityItems: [url], applicationActivities: nil), animated: true)
            })
        }

        let appActions: [UIMenuElement] = [
            UIAction(title: "New Tab", image: UIImage(systemName: "plus.square")) { [weak self] _ in self?.openTab(url: nil, tor: false) },
            UIAction(title: "New Tor Tab", image: OnionIcon.image(pointSize: 18)) { [weak self] _ in self?.openTab(url: nil, tor: true) },
            UIAction(title: "Settings", image: UIImage(systemName: "gearshape")) { [weak self] _ in
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
                                    image: UIImage(systemName: isFav ? "star.fill" : "star")) { [weak self] _ in
                FavoritesStore.shared.toggle(url: url, title: tab.webView.title ?? url.host ?? url.absoluteString)
                self?.updateChrome()
            })

            if let host = url.host {
                let normalized = WhitelistStore.normalize(host)
                let trusted = WhitelistStore.shared.isWhitelisted(host: normalized)
                actions.append(UIAction(title: trusted ? "Untrust Site" : "Trust Site",
                                        image: UIImage(systemName: trusted ? "checkmark.shield.fill" : "checkmark.shield")) { [weak self] _ in
                    if trusted { WhitelistStore.shared.remove(host: normalized) } else { WhitelistStore.shared.add(host: normalized) }
                    self?.showToast(trusted ? "\(normalized) can no longer redirect or open pop-ups" : "Trusted \(normalized) with redirects and pop-ups")
                    self?.updateChrome()
                })

                let base = DomainUtil.baseDomain(host)
                let paused = ContentBlocker.shared.paused.contains(host: host)
                actions.append(UIAction(title: paused ? "Resume Blocking on \(base)" : "Pause Blocking on \(base)",
                                        image: UIImage(systemName: paused ? "play.circle" : "pause.circle")) { [weak self] _ in
                    ContentBlocker.shared.paused.toggle(host: host)
                    tab.applyContentRules(for: host, force: true)
                    tab.webView.reload()
                    self?.updateChrome()
                })
            }

            actions.append(UIAction(title: "Hide Element…", image: UIImage(systemName: "eye.slash")) { [weak self] _ in
                self?.select(index: index)
                self?.startPicking()
            })
        }

        actions.append(UIAction(title: "Close Tab", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
            self?.close(tab: tab)
        })
        if tabs.count > 1 {
            actions.append(UIAction(title: "Close Other Tabs", image: UIImage(systemName: "xmark.square")) { [weak self] _ in
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

    private func showToast(_ message: String) {
        let label = PaddedLabel()
        label.text = message
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        label.layer.cornerRadius = 10
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
            UIView.animate(withDuration: 0.25, delay: 1.6, options: [], animations: { label.alpha = 0 }) { _ in
                label.removeFromSuperview()
            }
        }
    }
}

// MARK: - Address field

extension BrowserContainerViewController: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        textField.text = currentTab?.webView.url?.absoluteString ?? ""
        DispatchQueue.main.async { textField.selectAll(nil) }
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
        if sidebar.isExpanded && traitCollection.horizontalSizeClass == .compact {
            setSidebarExpanded(false, animated: true)
        }
    }

    func sidebarDidClose(index: Int) {
        guard tabs.indices.contains(index) else { return }
        close(tab: tabs[index])
    }

    func sidebarDidRequestNewTab(tor: Bool?) {
        openTab(url: nil, tor: tor)
    }

    func sidebarDidToggleExpanded() {
        setSidebarExpanded(!sidebar.isExpanded, animated: true)
    }

    func sidebarMenu(for index: Int) -> UIMenu? {
        tabMenu(for: index)
    }
}

// MARK: - Tab delegate

extension BrowserContainerViewController: TabDelegate {
    func tabDidChange(_ tab: Tab) {
        if tab === currentTab { updateChrome() } else { refreshSidebar() }
    }

    func tab(_ tab: Tab, toast message: String) {
        if tab === currentTab { showToast(message) }
    }

    func tab(_ tab: Tab, openInNewTab url: URL) {
        openTab(url: url, tor: tab.isTor)
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
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
    }
}

final class TorConnectingView: UIView {
    private let label = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let icon = UIImageView(image: OnionIcon.image(pointSize: 44))

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
        let stack = UIStackView(arrangedSubviews: [icon, label, progress])
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
        case .failed(let why):
            label.text = "Tor couldn't connect (\(why)).\nRestart the app to try again."
        default:
            label.text = "Connecting to Tor…"
        }
    }
}

final class PickerBanner: UIView {
    var onCancel: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.55, green: 0.18, blue: 0.32, alpha: 0.95)
        layer.cornerRadius = 12
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
