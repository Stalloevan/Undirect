import UIKit
import WebKit
import Network

/// Small pictures of each tab's page, kept in memory only (nothing is ever
/// written to disk, for normal and Tor tabs alike). Stored as compressed
/// JPEG so a few dozen tabs cost a couple of megabytes.
final class TabSnapshotStore {
    static let shared = TabSnapshotStore()

    private var data: [UUID: Data] = [:]  // main thread only
    private let encodeQueue = DispatchQueue(label: "undirect.tabsnapshots", qos: .utility)

    func image(for id: UUID) -> UIImage? {
        data[id].flatMap { UIImage(data: $0) }
    }

    func has(_ id: UUID) -> Bool { data[id] != nil }

    func remove(_ id: UUID) { data.removeValue(forKey: id) }

    /// Downscales and compresses off the main thread, then keeps the result.
    func store(_ image: UIImage, for id: UUID) {
        encodeQueue.async {
            let small = Self.downscaled(image)
            guard let jpeg = small.jpegData(compressionQuality: 0.55) else { return }
            DispatchQueue.main.async { self.data[id] = jpeg }
        }
    }

    private static func downscaled(_ image: UIImage) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        guard pixelWidth > 600 else { return image }
        let factor = 600 / pixelWidth
        let size = CGSize(width: 600, height: (image.size.height * image.scale * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// Decides which tabs are loaded and which are unloaded to save memory.
///
/// - At launch only the tab on screen loads first. Once it has finished, the
///   other tabs are loaded one at a time (normal tabs, then Tor tabs), each
///   photographed and then unloaded again. That happens once per tab per run.
///   Afterwards, switching to a tab shows its picture while the page loads.
/// - A background tab is unloaded after 10 idle minutes (sooner when the
///   system is short on memory), except the 3 most recently used ones.
/// - Anything live keeps its tab loaded: media, an open socket or event
///   stream, text typed into a form, a running download.
final class TabLifecycle {

    enum Pressure { case normal, warning, critical }

    private let tabs: () -> [Tab]
    private let current: () -> Tab?
    private let host: UIView
    private let frameProvider: () -> CGRect

    private var pressure: Pressure = .normal
    private var pressureReset: DispatchWorkItem?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var timer: Timer?

    private var warmedThisRun = Set<UUID>()
    private var warming: Tab?
    private var warmTimeout: DispatchWorkItem?
    private var warmStartedAt: Date?
    private var warmCount = 0
    private var warmUpArmed = false
    private var warmUpFallback: DispatchWorkItem?
    private var finishingWarm = false

    private let pathMonitor = NWPathMonitor()
    private var pathUsable = true
    private var pathIsExpensive = false

    init(tabs: @escaping () -> [Tab], current: @escaping () -> Tab?, host: UIView, frame: @escaping () -> CGRect) {
        self.tabs = tabs
        self.current = current
        self.host = host
        self.frameProvider = frame
    }

    deinit {
        timer?.invalidate()
        pressureSource?.cancel()
        pathMonitor.cancel()
    }

    // MARK: Start

    func start() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let event = source?.data else { return }
            self.pressureChanged(event.contains(.critical) ? .critical : .warning)
        }
        source.resume()
        pressureSource = source

        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.pathUsable = path.status == .satisfied
                self?.pathIsExpensive = path.isExpensive || path.isConstrained
                self?.pumpWarmUp()
            }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.enforce()
            self?.pumpWarmUp()
        }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(pageFinished(_:)), name: Tab.didFinishPageLoad, object: nil)
        nc.addObserver(self, selector: #selector(settingsChanged), name: Settings.didChange, object: nil)
        nc.addObserver(self, selector: #selector(torChanged), name: TorManager.stateDidChange, object: nil)
    }

    /// Begin loading the other tabs once the tab on screen has finished (or
    /// after a few seconds regardless, so a slow page can't block them forever).
    func armWarmUp() {
        guard !warmUpArmed else { return }
        warmUpArmed = true
        let fallback = DispatchWorkItem { [weak self] in self?.pumpWarmUp(force: true) }
        warmUpFallback = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: fallback)
        pumpWarmUp()
    }

    @objc private func pageFinished(_ note: Notification) {
        if (note.object as? Tab) === current() { pumpWarmUp() }
    }

    @objc private func settingsChanged() { pumpWarmUp() }
    @objc private func torChanged() { pumpWarmUp() }

    // MARK: Warm-up

    private var warmingAllowed: Bool {
        switch Settings.shared.backgroundLoading {
        case .off: return false
        case .always: return pathUsable
        case .wifiOnly: return pathUsable && !pathIsExpensive
        }
    }

    private func nextCandidate() -> Tab? {
        let cur = current()
        let candidates = tabs().filter {
            $0 !== cur && $0.isDeferred && !$0.isPopup && !$0.everLoadedThisRun
                && !warmedThisRun.contains($0.id) && $0.url != nil
        }
        // Normal tabs first, Tor tabs after (Tor loads are slow and shouldn't hold the rest up).
        return candidates.first { !$0.isTor } ?? candidates.first
    }

    func pumpWarmUp(force: Bool = false) {
        guard warmUpArmed, warming == nil, warmingAllowed, let cur = current() else { return }
        // The tab you're on gets everything first.
        if !force && (cur.webView.isLoading || cur.isRestoring || cur.isWaitingForTor) { return }
        guard let next = nextCandidate() else {
            if warmCount > 0, warmStartedAt != nil {
                let seconds = Date().timeIntervalSince(warmStartedAt!)
                AppLog.shared.log(String(format: "Background tabs ready: %d loaded and pictured in %.0f s", warmCount, seconds), category: "tabs")
                warmStartedAt = nil
                warmCount = 0
            }
            return
        }
        warm(next)
    }

    private func warm(_ tab: Tab) {
        if warmStartedAt == nil { warmStartedAt = Date(); warmCount = 0 }
        warming = tab
        warmedThisRun.insert(tab.id)
        warmCount += 1

        // Loaded off to the side, behind the page, so it renders (a picture
        // can't be taken of a view that isn't in a window).
        tab.webView.translatesAutoresizingMaskIntoConstraints = true
        tab.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tab.webView.frame = frameProvider()
        host.addSubview(tab.webView)

        tab.onLoadSettled = { [weak self, weak tab] in
            guard let self, let tab else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.warmLoaded(tab) }
        }
        let limit: TimeInterval = tab.isTor ? 60 : 25
        let timeout = DispatchWorkItem { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.warmLoaded(tab)
        }
        warmTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + limit, execute: timeout)

        tab.beginWarmUp()
    }

    private func warmLoaded(_ tab: Tab) {
        guard warming === tab, tab.isWarmingUp, !finishingWarm else { return }
        finishingWarm = true
        warmTimeout?.cancel()
        tab.onLoadSettled = nil
        // A load that failed or never started: put the tab back as it was
        // (it loads normally when opened) instead of leaving a broken page.
        guard tab.isLoadedLive else {
            tab.revertWarmUp()
            tab.webView.removeFromSuperview()
            endWarm(tab)
            return
        }
        let finish = { [weak self] in
            guard let self else { return }
            tab.checkKeepAlive { reason in
                if tab === self.current() || !tab.isWarmingUp {
                    // The person went to it meanwhile.
                    self.endWarm(tab)
                    return
                }
                tab.endWarmUp()
                if reason == nil {
                    tab.discard()
                } else {
                    AppLog.shared.log("Kept \(tab.host ?? "a tab") loaded (\(reason ?? ""))", category: "tabs")
                }
                tab.webView.removeFromSuperview()
                self.endWarm(tab)
            }
        }
        tab.captureSnapshotAsync(finish)
    }

    private func endWarm(_ tab: Tab) {
        if warming === tab { warming = nil }
        finishingWarm = false
        pumpWarmUp()
    }

    // MARK: Tab switching

    /// The person opened `tab`: it stops being a background job and counts as used.
    func userSelected(_ tab: Tab) {
        if warming === tab {
            warmTimeout?.cancel()
            warming = nil
            finishingWarm = false
        }
        tab.userTookOver()
        DispatchQueue.main.async { [weak self] in self?.pumpWarmUp() }
    }

    func tabClosed(_ tab: Tab) {
        if warming === tab { warmTimeout?.cancel(); warming = nil; finishingWarm = false }
        warmedThisRun.insert(tab.id)
        TabSnapshotStore.shared.remove(tab.id)
        DispatchQueue.main.async { [weak self] in self?.pumpWarmUp() }
    }

    // MARK: Unloading

    private func pressureChanged(_ level: Pressure) {
        pressure = level
        pressureReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.pressure = .normal }
        pressureReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: reset)
        AppLog.shared.log("Memory \(level == .critical ? "critically low" : "low"): unloading idle tabs sooner", category: "tabs")
        enforce()
    }

    func appDidEnterBackground() { enforce() }

    /// Unloads background tabs that have been idle long enough. Never the tab
    /// on screen, a tab being warmed, or one with something live in it.
    func enforce() {
        let cur = current()
        let now = Date()
        let candidates = tabs()
            .filter { $0 !== cur && $0.isLoadedLive && !$0.isWarmingUp && !$0.webView.isLoading }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }

        let protectedRecent: Int
        let idleLimit: TimeInterval
        switch pressure {
        case .normal: protectedRecent = 3; idleLimit = 600
        case .warning: protectedRecent = 1; idleLimit = 120
        case .critical: protectedRecent = 0; idleLimit = 20
        }
        for (rank, tab) in candidates.enumerated() where rank >= protectedRecent {
            let idle = now.timeIntervalSince(tab.lastActiveAt)
            guard idle > idleLimit else { continue }
            tab.checkKeepAlive { [weak self, weak tab] reason in
                guard let self, let tab, tab !== self.current(), tab.isLoadedLive, !tab.isWarmingUp else { return }
                if let reason {
                    AppLog.shared.log("Kept \(tab.host ?? "a tab") loaded (\(reason))", category: "tabs")
                    return
                }
                if tab.discard() {
                    AppLog.shared.log("Unloaded \(tab.host ?? "a tab") after \(Int(idle / 60)) min idle", category: "tabs")
                }
            }
        }
    }
}
