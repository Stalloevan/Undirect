import UIKit

// MARK: - Theme

enum AppTheme: String, CaseIterable {
    case catppuccin, nord, retro95

    var title: String {
        switch self {
        case .catppuccin: return "Catppuccin"
        case .nord: return "Nord"
        case .retro95: return "Retro"
        }
    }
}

private struct ThemePalette {
    let background: UIColor
    let bar: UIColor
    let surface: UIColor
    let field: UIColor
    let accent: UIColor
    let tor: UIColor
    let text: UIColor
    let secondaryText: UIColor
    let cornerRadius: CGFloat
    let smallCornerRadius: CGFloat
    let isDark: Bool
}

/// Reads live from Settings.shared.appTheme, so every call site (which the
/// whole app already addresses as plain `Theme.background` etc.) picks up
/// the current theme automatically. A theme change rebuilds the browser's
/// view hierarchy from scratch (see SceneDelegate) rather than trying to
/// live-restyle every already-built view, so these values only need to be
/// correct at the moment each screen is (re)constructed.
enum Theme {
    private static func palette() -> ThemePalette {
        switch Settings.shared.appTheme {
        case .catppuccin:
            // Kept the softest, most rounded of the three.
            return ThemePalette(
                background: UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1),
                bar: UIColor(red: 0.11, green: 0.11, blue: 0.14, alpha: 1),
                surface: UIColor(red: 0.15, green: 0.15, blue: 0.19, alpha: 1),
                field: UIColor(red: 0.19, green: 0.19, blue: 0.24, alpha: 1),
                accent: UIColor(red: 0.80, green: 0.65, blue: 0.97, alpha: 1),
                tor: UIColor(red: 0.62, green: 0.45, blue: 0.95, alpha: 1),
                text: UIColor(white: 0.92, alpha: 1),
                secondaryText: UIColor(white: 0.62, alpha: 1),
                cornerRadius: 16,
                smallCornerRadius: 9,
                isDark: true
            )
        case .nord:
            // Same Nord palette, but hard, crisp, unrounded edges throughout.
            return ThemePalette(
                background: UIColor(red: 0.098, green: 0.114, blue: 0.145, alpha: 1),
                bar: UIColor(red: 0.149, green: 0.169, blue: 0.212, alpha: 1),
                surface: UIColor(red: 0.180, green: 0.204, blue: 0.251, alpha: 1),
                field: UIColor(red: 0.231, green: 0.259, blue: 0.318, alpha: 1),
                accent: UIColor(red: 0.533, green: 0.753, blue: 0.816, alpha: 1),
                tor: UIColor(red: 0.506, green: 0.631, blue: 0.757, alpha: 1),
                text: UIColor(red: 0.925, green: 0.937, blue: 0.957, alpha: 1),
                secondaryText: UIColor(red: 0.635, green: 0.663, blue: 0.710, alpha: 1),
                cornerRadius: 0,
                smallCornerRadius: 0,
                isDark: true
            )
        case .retro95:
            // A warm beige retro-computer look (cream chassis, amber CRT
            // accent, dark brown text, teal-green secondary accent) rather
            // than Windows-95-specific gray/navy. There's no true 3D bevel
            // rendering here — that would mean reworking every custom-drawn
            // control's border code — but the palette and squared-off
            // corners alone get most of the way to the look.
            return ThemePalette(
                background: UIColor(red: 0.827, green: 0.784, blue: 0.702, alpha: 1),
                bar: UIColor(red: 0.780, green: 0.729, blue: 0.639, alpha: 1),
                surface: UIColor(red: 0.780, green: 0.729, blue: 0.639, alpha: 1),
                field: UIColor(red: 0.949, green: 0.925, blue: 0.867, alpha: 1),
                accent: UIColor(red: 0.541, green: 0.325, blue: 0.129, alpha: 1),
                tor: UIColor(red: 0.212, green: 0.400, blue: 0.361, alpha: 1),
                text: UIColor(red: 0.157, green: 0.125, blue: 0.078, alpha: 1),
                secondaryText: UIColor(red: 0.416, green: 0.361, blue: 0.290, alpha: 1),
                cornerRadius: 0,
                smallCornerRadius: 0,
                isDark: false
            )
        }
    }

    static var background: UIColor { palette().background }
    static var bar: UIColor { palette().bar }
    static var surface: UIColor { palette().surface }
    static var field: UIColor { palette().field }
    static var accent: UIColor { palette().accent }
    static var tor: UIColor { palette().tor }
    static var text: UIColor { palette().text }
    static var secondaryText: UIColor { palette().secondaryText }
    static var cornerRadius: CGFloat { palette().cornerRadius }
    static var smallCornerRadius: CGFloat { palette().smallCornerRadius }
    static var isDark: Bool { palette().isDark }
    static var statusBarStyle: UIStatusBarStyle { isDark ? .lightContent : .darkContent }
    static var keyboardAppearance: UIKeyboardAppearance { isDark ? .dark : .light }
    /// Rounded floating cards for Catppuccin's soft modern look; flush,
    /// edge-to-edge sections for Nord's crisp edges and Retro's blocky panels.
    static var tableViewStyle: UITableView.Style { Settings.shared.appTheme == .catppuccin ? .insetGrouped : .grouped }

    /// SF Symbols render in visibly different letterform styles depending on
    /// the font design behind them — this is what gives each theme its own
    /// icon character without needing a per-symbol-name mapping.
    private static var symbolDesign: UIFontDescriptor.SystemDesign {
        switch Settings.shared.appTheme {
        case .catppuccin: return .rounded
        case .nord: return .monospaced
        case .retro95: return .serif
        }
    }

    /// Everforest (light variant)'s well-known accent colors, used as the
    /// retro theme's multicolor icon palette.
    private static let everforestPalette: [UIColor] = [
        UIColor(red: 0.553, green: 0.631, blue: 0.004, alpha: 1), // green
        UIColor(red: 0.961, green: 0.490, blue: 0.149, alpha: 1), // orange
        UIColor(red: 0.208, green: 0.655, blue: 0.486, alpha: 1)  // aqua
    ]

    static func icon(_ name: String, pointSize: CGFloat = 17, weight: UIImage.SymbolWeight = .regular) -> UIImage? {
        let base = UIFont.systemFont(ofSize: pointSize, weight: .regular).fontDescriptor
        let font: UIFont
        if let designed = base.withDesign(symbolDesign) {
            font = UIFont(descriptor: designed, size: pointSize)
        } else {
            font = UIFont.systemFont(ofSize: pointSize)
        }
        var config = UIImage.SymbolConfiguration(font: font).applying(UIImage.SymbolConfiguration(weight: weight))
        if Settings.shared.appTheme == .retro95 {
            config = config.applying(UIImage.SymbolConfiguration(paletteColors: everforestPalette))
        }
        return UIImage(systemName: name, withConfiguration: config)
    }

    /// Adds a solid, hard-edged, offset drop shadow — the classic "blocky"
    /// retro look. A no-op (and clears any previously-applied shadow) on the
    /// other themes. Call again whenever the view's bounds change (e.g. from
    /// layoutSubviews), since the shadow path is a fixed snapshot of them.
    static func applyBlockShadow(to view: UIView) {
        guard Settings.shared.appTheme == .retro95, view.bounds.width > 0, view.bounds.height > 0 else {
            view.layer.shadowOpacity = 0
            return
        }
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOffset = CGSize(width: 3, height: 3)
        view.layer.shadowRadius = 0
        view.layer.shadowOpacity = 1
        view.layer.shadowPath = UIBezierPath(rect: view.bounds).cgPath
    }
}

// MARK: - Settings

enum BlocklistLevel: String, CaseIterable {
    case off, standard, strict

    var title: String {
        switch self {
        case .off: return "Off"
        case .standard: return "Standard"
        case .strict: return "Strict"
        }
    }

    var detail: String {
        switch self {
        case .off: return "No domain blocking"
        case .standard: return "~44k ad/tracker domains (HaGeZi Light)"
        case .strict: return "~164k domains (HaGeZi Multi). First compile is slower."
        }
    }

    var resourceName: String? {
        switch self {
        case .off: return nil
        case .standard: return "blocklist-light"
        case .strict: return "blocklist-strict"
        }
    }
}

enum CookieCleanupMode: String, CaseIterable {
    case onTabClose, onBackground, never

    var title: String {
        switch self {
        case .onTabClose: return "When a tab closes"
        case .onBackground: return "When leaving the app"
        case .never: return "Never"
        }
    }
}

enum SidebarState: String, CaseIterable {
    case hidden, minimal, full
}

enum SidebarPosition: String, CaseIterable {
    case leading, trailing
    var title: String { self == .leading ? "Left" : "Right" }
}

enum NTPSection: String, CaseIterable, Codable {
    case favorites, stats, tor

    var title: String {
        switch self {
        case .favorites: return "Favorites"
        case .stats: return "Blocking statistics"
        case .tor: return "Tor"
        }
    }
}

final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("UndirectSettingsDidChange")

    private let defaults = UserDefaults.standard
    private init() {}

    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private func set(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    var blocklistLevel: BlocklistLevel {
        get { BlocklistLevel(rawValue: defaults.string(forKey: "s.blocklist") ?? "") ?? .strict }
        set { set(newValue.rawValue, "s.blocklist") }
    }
    var cosmeticFiltering: Bool {
        get { bool("s.cosmetic", true) }
        set { set(newValue, "s.cosmetic") }
    }
    var stripTrackers: Bool {
        get { bool("s.stripTrackers", true) }
        set { set(newValue, "s.stripTrackers") }
    }
    var clickThrough: Bool {
        get { bool("s.clickThrough", true) }
        set { set(newValue, "s.clickThrough") }
    }
    var blockThirdPartyCookies: Bool {
        get { bool("s.block3pCookies", true) }
        set { set(newValue, "s.block3pCookies") }
    }
    var spoofAnalyticsCookies: Bool {
        get { bool("s.spoofCookies", true) }
        set { set(newValue, "s.spoofCookies") }
    }
    var cookieCleanup: CookieCleanupMode {
        get { CookieCleanupMode(rawValue: defaults.string(forKey: "s.cleanup") ?? "") ?? .onTabClose }
        set { set(newValue.rawValue, "s.cleanup") }
    }
    var torForNewTabs: Bool {
        get { bool("s.torDefault", false) }
        set { set(newValue, "s.torDefault") }
    }
    var preloadFavorites: Bool {
        get { bool("s.preload", true) }
        set { set(newValue, "s.preload") }
    }
    var appTheme: AppTheme {
        get { AppTheme(rawValue: defaults.string(forKey: "s.appTheme") ?? "") ?? .catppuccin }
        set { set(newValue.rawValue, "s.appTheme") }
    }
    var sidebarState: SidebarState {
        get { SidebarState(rawValue: defaults.string(forKey: "s.sidebarState") ?? "") ?? .minimal }
        set { defaults.set(newValue.rawValue, forKey: "s.sidebarState") }
    }
    var sidebarPosition: SidebarPosition {
        get { SidebarPosition(rawValue: defaults.string(forKey: "s.sidebarPosition") ?? "") ?? .leading }
        set { set(newValue.rawValue, "s.sidebarPosition") }
    }
    /// Auto-dismisses cookie-consent banners instead of showing them. Off = see them normally.
    var autoHandleCookieBanners: Bool {
        get { bool("s.autoConsent", true) }
        set { set(newValue, "s.autoConsent") }
    }

    // New tab page layout
    var ntpOrder: [NTPSection] {
        get {
            let raw = defaults.stringArray(forKey: "s.ntpOrder") ?? []
            var order = raw.compactMap(NTPSection.init(rawValue:))
            for s in NTPSection.allCases where !order.contains(s) { order.append(s) }
            return order
        }
        set { set(newValue.map(\.rawValue), "s.ntpOrder") }
    }
    var ntpHidden: Set<NTPSection> {
        get { Set((defaults.stringArray(forKey: "s.ntpHidden") ?? []).compactMap(NTPSection.init(rawValue:))) }
        set { set(newValue.map(\.rawValue), "s.ntpHidden") }
    }
    var ntpVisibleSections: [NTPSection] { ntpOrder.filter { !ntpHidden.contains($0) } }
    var ntpColumns: Int {
        get { let v = defaults.integer(forKey: "s.ntpColumns"); return v == 0 ? 4 : min(max(v, 3), 6) }
        set { set(newValue, "s.ntpColumns") }
    }
    var ntpShowTitles: Bool {
        get { bool("s.ntpTitles", true) }
        set { set(newValue, "s.ntpTitles") }
    }
    var ntpDetailedStats: Bool {
        get { bool("s.ntpDetailedStats", true) }
        set { set(newValue, "s.ntpDetailedStats") }
    }
}

// MARK: - Domains

enum DomainUtil {
    private static let secondLevelMarkers: Set<String> = [
        "co", "com", "org", "net", "ac", "gov", "edu", "ne", "or", "go", "gv", "ltd", "plc", "sch", "nic", "mil"
    ]

    static func normalize(_ host: String) -> String {
        var h = host.lowercased()
        while h.hasPrefix("www.") { h.removeFirst(4) }
        if h.hasSuffix(".") { h.removeLast() }
        return h
    }

    /// Approximates the registrable domain ("news.bbc.co.uk" -> "bbc.co.uk").
    static func baseDomain(_ host: String) -> String {
        let h = normalize(host)
        let labels = h.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return h }
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return h }
        let tld = labels[labels.count - 1]
        let sld = labels[labels.count - 2]
        if tld.count == 2 && secondLevelMarkers.contains(sld) {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }

    static func sameSite(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
        return baseDomain(a) == baseDomain(b)
    }
}

/// A persisted set of domains (matched with their subdomains).
final class DomainSetStore {
    static let didChange = Notification.Name("UndirectDomainSetDidChange")

    private let key: String
    private var domains: Set<String>

    init(key: String) {
        self.key = key
        domains = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    func contains(host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        let h = DomainUtil.normalize(host)
        return domains.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    func add(host: String) {
        domains.insert(DomainUtil.baseDomain(host))
        persist()
    }

    func remove(host: String) {
        domains.remove(DomainUtil.baseDomain(host))
        domains.remove(DomainUtil.normalize(host))
        persist()
    }

    @discardableResult
    func toggle(host: String) -> Bool {
        if contains(host: host) { remove(host: host); return false }
        add(host: host)
        return true
    }

    func all() -> [String] { domains.sorted() }

    func removeAll() {
        domains.removeAll()
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(Array(domains), forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

// MARK: - Stats

enum StatKind: String, CaseIterable {
    case requests, redirects, popups, trackers, cookies

    var title: String {
        switch self {
        case .requests: return "Ads & trackers"
        case .redirects: return "Redirects"
        case .popups: return "Pop-ups"
        case .trackers: return "Link tracking"
        case .cookies: return "Cookies"
        }
    }

    var symbol: String {
        switch self {
        case .requests: return "shield.lefthalf.filled"
        case .redirects: return "arrow.uturn.left"
        case .popups: return "macwindow.badge.plus"
        case .trackers: return "link"
        case .cookies: return "circle.grid.cross"
        }
    }
}

final class BlockStats {
    static let shared = BlockStats()
    static let didChange = Notification.Name("UndirectStatsDidChange")

    private var counts: [String: Int]
    private var saveScheduled = false

    private init() {
        counts = (UserDefaults.standard.dictionary(forKey: "stats.counts") as? [String: Int]) ?? [:]
        if UserDefaults.standard.object(forKey: "stats.since") == nil {
            UserDefaults.standard.set(Date(), forKey: "stats.since")
        }
    }

    var since: Date { (UserDefaults.standard.object(forKey: "stats.since") as? Date) ?? Date() }

    func count(_ kind: StatKind) -> Int { counts[kind.rawValue] ?? 0 }
    var total: Int { StatKind.allCases.reduce(0) { $0 + count($1) } }

    func increment(_ kind: StatKind, by amount: Int = 1) {
        guard amount > 0 else { return }
        let apply = {
            self.counts[kind.rawValue, default: 0] += amount
            self.scheduleSave()
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    func reset() {
        counts = [:]
        UserDefaults.standard.set(Date(), forKey: "stats.since")
        scheduleSave()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.saveScheduled = false
            UserDefaults.standard.set(self.counts, forKey: "stats.counts")
        }
    }

    func flush() {
        UserDefaults.standard.set(counts, forKey: "stats.counts")
    }
}
