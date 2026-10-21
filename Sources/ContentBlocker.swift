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

    private static func resourceData(_ name: String) -> Data? {
        Bundle.main.url(forResource: name, withExtension: "txt").flatMap { try? Data(contentsOf: $0) }
    }

    /// Ad/tracker hosts the big lists leave out, and URL patterns (ad loaders
    /// served from any site, tracking pixels on otherwise-useful hosts). These
    /// live in bundled text files so Tools/adblock-test checks the very same
    /// data the app ships.
    private static let extraDomains: [String] = resourceData("blocklist-extra").map(ContentBlocker.parseDomains) ?? []
    /// Hosts blocked only as page resources, never as a page or frame you open.
    private static let extraResourceDomains: [String] = resourceData("blocklist-extra-resources").map(ContentBlocker.parseDomains) ?? []
    private static let extraURLFilters: [String] = {
        guard let data = resourceData("blocklist-extra-urls") else { return [] }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }()

    /// Bump when the JSON *format* produced below changes.
    private static let rulesFormat = "r3"

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
        cosmeticSelectors.joined() + shieldDomains.joined() + extraURLFilters.joined(separator: "\n")
            + extraDomains.joined(separator: "\n") + extraResourceDomains.joined(separator: "\n")
    )

    /// `a` covers `b` when it is `b` or one of its parent domains.
    private static func covers(_ a: String, _ b: String) -> Bool { b == a || b.hasSuffix("." + a) }

    /// A list entry the person has chosen to allow (an allowed name drops the
    /// entries above it and below it).
    private static func isExcluded(_ entry: String, by allowed: [String]) -> Bool {
        allowed.contains { covers($0, entry) || covers(entry, $0) }
    }

    private static func shortHash(_ strings: [String]) -> String {
        let digest = SHA256.hash(data: Data(strings.sorted().joined(separator: ",").utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

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
        let userBlocked = UserBlocklist.shared.blocked
        let userAllowed = UserBlocklist.shared.allowed
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

            // Domains the person allowed: dropped from the chunk that holds
            // them (only that chunk is recompiled; the rest stay cached).
            let listDomains = list?.domains ?? []
            var excludedByChunk: [Int: [String]] = [:]
            var excluded = Set<String>()
            if !userAllowed.isEmpty {
                for (i, d) in listDomains.enumerated() where Self.isExcluded(d, by: userAllowed) {
                    excludedByChunk[i / Self.chunkSize, default: []].append(d)
                    excluded.insert(d)
                }
            }
            let extras = level == .off ? [] : Self.extraDomains
            let keptExtras = extras.filter { !Self.isExcluded($0, by: userAllowed) }
            let keptResourceOnly = (level == .off ? [] : Self.extraResourceDomains).filter { !Self.isExcluded($0, by: userAllowed) }
            let keptShields = Self.shieldDomains.filter { !Self.isExcluded($0, by: userAllowed) }
            let excludedSet = excluded
            let allowedTag = userAllowed.isEmpty ? "" : "-x" + Self.shortHash(userAllowed)

            // Each spec: identifier + a closure producing its JSON (only built,
            // off the main thread, if WebKit doesn't have it cached).
            var specs: [(String, () -> String)] = []
            for index in 0..<chunkCount {
                let tag = excludedByChunk[index].map { "-x" + Self.shortHash($0) } ?? ""
                specs.append(("undirect-\(level.rawValue)-\(index)-b\(version)\(tag)", {
                    let start = min(index * Self.chunkSize, listDomains.count)
                    let end = min(start + Self.chunkSize, listDomains.count)
                    let slice = listDomains[start..<end]
                    return Self.domainRulesJSON(excludedSet.isEmpty ? Array(slice) : slice.filter { !excludedSet.contains($0) })
                }))
            }
            let fixed = Self.staticRulesKey
            if cosmetic {
                specs.append(("undirect-cosmetic-b\(fixed)", { Self.cosmeticJSON() }))
            }
            if level != .off {
                specs.append(("undirect-extra-b\(fixed)\(allowedTag)", { Self.domainRulesJSON(keptExtras) }))
                specs.append(("undirect-extrares-b\(fixed)\(allowedTag)", { Self.shieldJSON(keptResourceOnly) }))
                specs.append(("undirect-urlfilters-b\(fixed)", { Self.urlFilterJSON() }))
            }
            if shields {
                specs.append(("undirect-shields-b\(fixed)\(allowedTag)", { Self.shieldJSON(keptShields) }))
            }
            if cookies {
                specs.append(("undirect-3pcookies-b\(fixed)", { Self.thirdPartyCookieJSON() }))
            }
            // The person's own blocks apply whatever the level, even Off.
            if !userBlocked.isEmpty {
                specs.append(("undirect-user-b\(Self.contentKey(userBlocked.joined(separator: "\n")))", { Self.domainRulesJSON(userBlocked) }))
            }

            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.compile(specs, generation: gen)
            }
            // In parallel: the domain set for blocking ad/tracker sites you'd
            // otherwise be sent to as a whole page.
            var set = Set(listDomains)
            if !excluded.isEmpty { set.subtract(excluded) }
            set.formUnion(keptExtras)
            set.formUnion(userBlocked)
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
                // The person's own lists and allow-list variants change often; drop them once unused.
                if id.hasPrefix("undirect-user-") || id.contains("-x") { store.removeContentRuleList(forIdentifier: id) { _ in }; continue }
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

    private static func domainRulesJSON(_ domains: [String]) -> String {
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

    /// Blocks by URL pattern regardless of domain — ad-loader scripts served
    /// from a site's own origin (such as the decoy `ads.js` / `pagead.js`
    /// ad-blocker test pages serve) and tracking pixels on useful hosts.
    private static func urlFilterJSON() -> String {
        // Built with a real JSON encoder: the patterns contain regex escapes
        // like `\.`, which aren't valid JSON escapes if pasted in raw — that
        // made WebKit reject this whole list (WKErrorDomain 6) before.
        let rules: [[String: Any]] = extraURLFilters.map { pattern in
            ["trigger": ["url-filter": pattern], "action": ["type": "block"]]
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func shieldJSON(_ domains: [String]) -> String {
        let types = ["raw", "script", "image", "style-sheet", "font", "media", "other"]
        let rules: [[String: Any]] = domains.map { domain in
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
