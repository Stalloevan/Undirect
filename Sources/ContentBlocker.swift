import Foundation
import WebKit

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
    private static let blockedScriptPatterns = [
        "/pagead\\.js", "/ads\\.js", "/widget/ads\\.", "/ad-loader\\.js", "/ad-manager\\.js"
    ]

    private var buildVersion: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
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

    /// (Re)builds the rule lists from the current settings.
    func rebuild() {
        generation += 1
        let gen = generation
        let level = Settings.shared.blocklistLevel
        let cosmetic = Settings.shared.cosmeticFiltering
        let cookies = Settings.shared.blockThirdPartyCookies
        let version = buildVersion
        isCompiling = true

        DispatchQueue.global(qos: .userInitiated).async {
            var domains: [String] = []
            if let name = level.resourceName,
               let url = Bundle.main.url(forResource: name, withExtension: "txt"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                domains = text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") && Self.isPlainDomain($0) }
            }

            // Each spec: identifier + a closure producing its JSON (only built if not cached).
            var specs: [(String, () -> String)] = []
            var index = 0
            var start = 0
            while start < domains.count {
                let end = min(start + Self.chunkSize, domains.count)
                let slice = domains[start..<end]
                specs.append(("undirect-\(level.rawValue)-\(index)-b\(version)", { Self.domainRulesJSON(slice) }))
                index += 1
                start = end
            }
            if cosmetic {
                specs.append(("undirect-cosmetic-b\(version)", { Self.cosmeticJSON() }))
            }
            if level != .off {
                specs.append(("undirect-scriptpatterns-b\(version)", { Self.scriptPatternJSON() }))
            }
            if cookies {
                specs.append(("undirect-3pcookies-b\(version)", { Self.thirdPartyCookieJSON() }))
            }
            let set = Set(domains)

            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.blockedDomains = set
                self.compile(specs, generation: gen)
            }
        }
    }

    private func compile(_ specs: [(String, () -> String)], generation gen: Int) {
        guard let store = WKContentRuleListStore.default() else { return }
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
                let json = spec.1()
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

        group.notify(queue: .main) {
            guard gen == self.generation else { return }
            self.ruleLists = results.compactMap { $0 }
            self.isCompiling = false
            AppLog.shared.log("Content rules compiled: \(self.ruleLists.count)/\(specs.count) lists, \(self.blockedDomains.count) blocked domains", category: "block")
            NotificationCenter.default.post(name: Self.didUpdate, object: nil)
            self.removeStaleLists(keeping: Set(specs.map { $0.0 }))
        }
    }

    private func removeStaleLists(keeping: Set<String>) {
        guard let store = WKContentRuleListStore.default() else { return }
        store.getAvailableContentRuleListIdentifiers { ids in
            for id in ids ?? [] where id.hasPrefix("undirect-") && !keeping.contains(id) {
                // Keep other levels of the same build cached so switching back is instant.
                if id.hasSuffix("-b\(self.buildVersion)") { continue }
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

    private static func isPlainDomain(_ s: String) -> Bool {
        s.contains(".") && s.unicodeScalars.allSatisfy {
            ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "." || $0 == "-" || $0 == "_"
        }
    }

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
        var s = "["
        var first = true
        for pattern in blockedScriptPatterns {
            if !first { s += "," }
            first = false
            s += "{\"trigger\":{\"url-filter\":\"\(pattern)\"},\"action\":{\"type\":\"block\"}}"
        }
        s += "]"
        return s
    }

    private static func thirdPartyCookieJSON() -> String {
        #"[{"trigger":{"url-filter":".*","load-type":["third-party"]},"action":{"type":"block-cookies"}}]"#
    }
}
