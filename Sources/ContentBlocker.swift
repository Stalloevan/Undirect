import Foundation
import WebKit
import CryptoKit

/// Pi-hole-style domain blocking, applied to the browser's own traffic.
///
/// iOS doesn't let an app filter system DNS without a VPN / Network Extension,
/// but inside our own WKWebViews we can do the equivalent: every request to a
/// listed domain (or any of its subdomains) is refused by WebKit before a
/// connection is made. The lists are compiled once into WKContentRuleLists and
/// cached by WebKit, so later launches are instant.
final class ContentBlocker {

    static let shared = ContentBlocker()
    static let didUpdate = Notification.Name("UndirectContentBlockerDidUpdate")

    /// Sites where the person paused ad/tracker blocking.
    let paused = DomainSetStore(key: "com.stalloevan.undirect.pausedBlocking")

    private(set) var ruleLists: [WKContentRuleList] = []
    private(set) var generation = 0
    private(set) var isCompiling = false
    private var blockedDomains: Set<String> = []

    private init() {}

    private static let chunkSize = 50_000

    private static let cosmeticSelectors = [
        ".adsbygoogle", "ins.adsbygoogle", "[id^=\"google_ads_iframe\"]", "[id^=\"div-gpt-ad\"]",
        "[data-google-query-id]", ".GoogleActiveViewElement", "iframe[src*=\"doubleclick.net\"]",
        "iframe[src*=\"googlesyndication.com\"]", "[id^=\"taboola-\"]", ".trc_rbox_container",
        ".OUTBRAIN", "[data-widget-id^=\"outbrain\"]", ".ob-widget", "[data-ad-slot]", "[data-ad-unit]",
        "[data-adunit]", ".ad-slot", ".ad-banner", ".advertisement", "amp-ad",
        "amp-embed[type=\"taboola\"]", "[aria-label=\"Advertisement\"]",
        // Ad-shaped test/bait elements used by common ad-blocker test pages.
        ".adbox", ".banner_ads", ".adsbox", ".textads", ".text-ad", ".ad-container", ".ads-container",
        ".sponsored-content"
    ]

    /// Path/filename patterns for ad and tracker scripts, matched regardless
    /// of which domain serves them — catches decoy/bait scripts that ad-
    /// blocker test pages serve from their own origin (so a domain-only list
    /// can't see them) as well as first-party-disguised ad loaders.
    /// IP-geolocation lookup services and analytics ingest hosts that the
    /// ordinary ad/tracker lists don't cover (e.g. the `ipwho.is` lookup and
    /// PostHog ingest used by privacy test pages). Blocked only as resources
    /// a page loads, never as a page you navigate to yourself.
    private static let shieldDomains = [
        "ipwho.is", "ipwhois.app", "ipwhois.io", "ipapi.co", "ipapi.com", "ipinfo.io", "ip-api.com",
        "ipify.org", "geojs.io", "ipgeolocation.io", "ipdata.co", "freeipapi.com", "geoplugin.net",
        "ip.sb", "db-ip.com", "extreme-ip-lookup.com", "ipregistry.co", "ipbase.com", "ipstack.com",
        "ipapi.is", "ipquery.io", "iplocation.net", "myip.com", "seeip.org", "ident.me", "icanhazip.com",
        "i.posthog.com", "eu.i.posthog.com", "us.i.posthog.com", "eu-assets.i.posthog.com",
        "us-assets.i.posthog.com", "app.posthog.com"
    ]

    private static let blockedScriptPatterns = [
        "/pagead\\.js", "/ads\\.js", "/widget/ads\\.", "/ad-loader\\.js", "/ad-manager\\.js"
    ]

    /// Bump when the JSON *format* produced below changes.
    private static let rulesFormat = "r2"

    /// Cache keys come from the content itself, not the build number, so an
    /// app update that doesn't touch the lists reuses the already-compiled
    /// rules instead of recompiling tens of thousands of them at launch.
    private static func contentKey(_ text: String) -> String {
        contentKey(Data(text.utf8))
    }

    private static func contentKey(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return rulesFormat + "-" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static let staticRulesKey: String = contentKey(
        cosmeticSelectors.joined() + shieldDomains.joined() + blockedScriptPatterns.joined()
    )

    /// Returns true if `host` or any parent domain is on the active list.
    func isBlocked(host: String?) -> Bool {
        guard let host, !blockedDomains.isEmpty else { return false }
        var h = DomainUtil.normalize(host)
        while true {
            if blockedDomains.contains(h) { return true }
            guard let dot = h.firstIndex(of: ".") else { return false }
            h = String(h[h.index(after: dot)...])
            if !h.contains(".") { return false }
        }
    }

    // MARK: Launch readiness

    /// True once the first set of rules is installed (or a short safety
    /// timeout has passed). Pages that load at launch wait for this, so the
    /// first requests aren't sent before ads and trackers are blocked.
    private(set) var initialRulesReady = false
    private var readyWaiters: [() -> Void] = []

    func whenInitialRulesReady(_ block: @escaping () -> Void) {
        // generation 0: nothing has asked for rules (e.g. a preview), don't wait.
        if initialRulesReady || generation == 0 { block() } else { readyWaiters.append(block) }
    }

    private func markInitialRulesReady() {
        guard !initialRulesReady else { return }
        initialRulesReady = true
        let waiters = readyWaiters
        readyWaiters = []
        waiters.forEach { $0() }
    }

    /// The parsed domain list, shared by the navigation check and any rule
    /// chunk that has to be compiled. Parsed at most once, on first use.
    private final class DomainList {
        private let data: Data
        private let lock = NSLock()
        private var parsed: [String]?
        init(data: Data) { self.data = data }
        var domains: [String] {
            lock.lock(); defer { lock.unlock() }
            if let parsed { return parsed }
            let result = ContentBlocker.parseDomains(data)
            parsed = result
            return result
        }
    }

    private static func chunkCountKey(level: BlocklistLevel, version: String) -> String {
        "com.stalloevan.undirect.rules.chunks.\(level.rawValue).\(version)"
    }

    /// (Re)builds the rule lists from the current settings.
    ///
    /// On a normal launch the compiled lists are already in WebKit's cache, so
    /// they're looked up straight away (their names are remembered from the
    /// last build) while the domain list is parsed in parallel for the
    /// navigation check — rules are ready in a fraction of the old time.
    func rebuild() {
        generation += 1
        let gen = generation
        let level = Settings.shared.blocklistLevel
        let cosmetic = Settings.shared.cosmeticFiltering
        let cookies = Settings.shared.blockThirdPartyCookies
        let shields = Settings.shared.blockIPLookups
        isCompiling = true
        if gen == 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, !self.initialRulesReady else { return }
                AppLog.shared.log("Content rules still compiling after 1.5 s; loading pages anyway", category: "block")
                self.markInitialRulesReady()
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let loaded: (version: String, list: DomainList?) = {
                guard let name = level.resourceName,
                      let url = Bundle.main.url(forResource: name, withExtension: "txt"),
                      let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                    return (Self.staticRulesKey, nil)
                }
                return (Self.contentKey(data), DomainList(data: data))
            }()
            let version = loaded.version
            let list = loaded.list
            let countKey = Self.chunkCountKey(level: level, version: version)
            let chunkCount: Int
            if list == nil {
                chunkCount = 0
            } else if let known = UserDefaults.standard.object(forKey: countKey) as? Int {
                chunkCount = known
            } else {
                // First build of this list: parse now to know how many chunks.
                let total = list?.domains.count ?? 0
                chunkCount = (total + Self.chunkSize - 1) / Self.chunkSize
                UserDefaults.standard.set(chunkCount, forKey: countKey)
            }

            // Each spec: identifier + a closure producing its JSON (only built,
            // off the main thread, if WebKit doesn't have it cached).
            var specs: [(String, () -> String)] = []
            for index in 0..<chunkCount {
                specs.append(("undirect-\(level.rawValue)-\(index)-b\(version)", {
                    let all = list?.domains ?? []
                    let start = min(index * Self.chunkSize, all.count)
                    let end = min(start + Self.chunkSize, all.count)
                    return Self.domainRulesJSON(all[start..<end])
                }))
            }
            let fixed = Self.staticRulesKey
            if cosmetic {
                specs.append(("undirect-cosmetic-b\(fixed)", { Self.cosmeticJSON() }))
            }
            if level != .off {
                specs.append(("undirect-scriptpatterns-b\(fixed)", { Self.scriptPatternJSON() }))
            }
            if shields {
                specs.append(("undirect-shields-b\(fixed)", { Self.shieldJSON() }))
            }
            if cookies {
                specs.append(("undirect-3pcookies-b\(fixed)", { Self.thirdPartyCookieJSON() }))
            }

            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.compile(specs, generation: gen)
            }
            // In parallel: the domain set for blocking ad/tracker sites you'd
            // otherwise be sent to as a whole page.
            let set = Set(list?.domains ?? [])
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.blockedDomains = set
            }
        }
    }

    private func compile(_ specs: [(String, () -> String)], generation gen: Int) {
        guard let store = WKContentRuleListStore.default() else { markInitialRulesReady(); return }
        var results = [WKContentRuleList?](repeating: nil, count: specs.count)
        let group = DispatchGroup()

        for (i, spec) in specs.enumerated() {
            group.enter()
            store.lookUpContentRuleList(forIdentifier: spec.0) { existing, _ in
                if let existing {
                    results[i] = existing
                    group.leave()
                    return
                }
                // Building tens of thousands of rules is heavy: do it off the
                // main thread, then hand it to WebKit to compile.
                DispatchQueue.global(qos: .userInitiated).async {
                    let json = spec.1()
                    DispatchQueue.main.async {
                        store.compileContentRuleList(forIdentifier: spec.0, encodedContentRuleList: json) { list, error in
                            if let error {
                                NSLog("Undirect: rule list \(spec.0) failed: \(error)")
                                AppLog.shared.log("Rule list \(spec.0) failed to compile: \(error.localizedDescription)", category: "block")
                            }
                            results[i] = list
                            group.leave()
                        }
                    }
                }
            }
        }

        group.notify(queue: .main) {
            guard gen == self.generation else { return }
            self.ruleLists = results.compactMap { $0 }
            self.isCompiling = false
            AppLog.shared.log("Content rules compiled: \(self.ruleLists.count)/\(specs.count) lists", category: "block")
            NotificationCenter.default.post(name: Self.didUpdate, object: nil)
            self.markInitialRulesReady()
            self.removeStaleLists(keeping: Set(specs.map { $0.0 }))
        }
    }

    /// One domain per line; blank lines and # comments skipped; only plain
    /// hostnames kept. Works on the raw bytes — several times faster than
    /// splitting and trimming Swift strings for 160k+ lines.
    fileprivate static func parseDomains(_ data: Data) -> [String] {
        var out: [String] = []
        out.reserveCapacity(data.count / 18)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count
            var i = 0
            while i < n {
                var start = i
                while i < n && bytes[i] != 0x0A { i += 1 }
                var end = i
                i += 1
                while start < end, bytes[start] == 0x20 || bytes[start] == 0x09 || bytes[start] == 0x0D { start += 1 }
                while end > start, bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09 || bytes[end - 1] == 0x0D { end -= 1 }
                guard end > start, bytes[start] != 0x23 else { continue }
                var plain = true
                var hasDot = false
                for j in start..<end {
                    let c = bytes[j]
                    if c == 0x2E { hasDot = true; continue }
                    if !((c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F) {
                        plain = false
                        break
                    }
                }
                if plain && hasDot {
                    out.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self))
                }
            }
        }
        return out
    }

    private func removeStaleLists(keeping: Set<String>) {
        guard let store = WKContentRuleListStore.default() else { return }
        store.getAvailableContentRuleListIdentifiers { ids in
            for id in ids ?? [] where id.hasPrefix("undirect-") && !keeping.contains(id) {
                // Keep other blocklist levels in the current format cached so
                // switching back is instant; drop everything older.
                if id.contains("-b\(Self.rulesFormat)-") { continue }
                store.removeContentRuleList(forIdentifier: id) { _ in }
            }
        }
    }

    /// Installs the current rule lists on a web view's content controller.
    func apply(to controller: WKUserContentController, paused isPaused: Bool) {
        controller.removeAllContentRuleLists()
        guard !isPaused else { return }
        for list in ruleLists { controller.add(list) }
    }

    // MARK: JSON builders

    private static func domainRulesJSON(_ domains: ArraySlice<String>) -> String {
        var s = "["
        s.reserveCapacity(domains.count * 100)
        var first = true
        for d in domains {
            if !first { s += "," }
            first = false
            s += "{\"trigger\":{\"url-filter\":\"^[^:]+://+([^:/]+\\\\.)?"
            s += d.replacingOccurrences(of: ".", with: "\\\\.")
            s += "[:/]\"},\"action\":{\"type\":\"block\"}}"
        }
        s += "]"
        return s
    }

    private static func cosmeticJSON() -> String {
        let rules: [[String: Any]] = [[
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": cosmeticSelectors.joined(separator: ", ")]
        ]]
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Blocks by filename/path regardless of domain — catches ad-loader
    /// scripts served from a site's own origin (which a domain list alone
    /// can't see) such as the decoy `ads.js` / `pagead.js` ad-blocker test
    /// pages serve from themselves specifically to check for this.
    private static func scriptPatternJSON() -> String {
        // Built with a real JSON encoder: the patterns contain regex escapes
        // like `\.`, which aren't valid JSON escapes if pasted in raw — that
        // made WebKit reject this whole list (WKErrorDomain 6) before.
        let rules: [[String: Any]] = blockedScriptPatterns.map { pattern in
            ["trigger": ["url-filter": pattern], "action": ["type": "block"]]
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func shieldJSON() -> String {
        let types = ["raw", "script", "image", "style-sheet", "font", "media", "other"]
        let rules: [[String: Any]] = shieldDomains.map { domain in
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            return [
                "trigger": ["url-filter": "^[^:]+://+([^:/]+\\.)?\(escaped)[:/]", "resource-type": types],
                "action": ["type": "block"]
            ]
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func thirdPartyCookieJSON() -> String {
        #"[{"trigger":{"url-filter":".*","load-type":["third-party"]},"action":{"type":"block-cookies"}}]"#
    }
}
