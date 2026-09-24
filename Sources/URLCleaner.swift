import Foundation

/// Removes link tracking before a page is requested:
/// - strips known tracking query parameters (utm_*, fbclid, gclid, ...)
/// - unwraps click-tracking redirect wrappers (Google /url, l.facebook.com, ...)
///   so you go straight to the destination.
enum URLCleaner {

    private static let trackingParams: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid",
        "igshid", "igsh", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp",
        "hsctatracking", "mkt_tok", "oly_anon_id", "oly_enc_id", "rb_clickid", "s_cid", "vero_conv",
        "vero_id", "wickedid", "srsltid", "_openstat", "cmpid", "ncid", "spm", "scm", "trk", "trkcampaign",
        "sc_cid", "epik", "ga_source", "ga_medium", "ga_campaign", "ga_content", "ga_term"
    ]

    /// Parameters only stripped on specific sites, because elsewhere they can be meaningful.
    private static let siteParams: [String: Set<String>] = [
        "youtube.com": ["si", "pp"],
        "youtu.be": ["si"],
        "spotify.com": ["si", "context"],
        "twitter.com": ["ref_src", "ref_url", "s", "t"],
        "x.com": ["ref_src", "ref_url", "s", "t"],
        "instagram.com": ["utm_source", "igshid", "igsh", "img_index"],
        "reddit.com": ["share_id", "ref", "ref_source", "rdt"],
        "amazon.com": ["pd_rd_r", "pd_rd_w", "pd_rd_wg", "pf_rd_p", "pf_rd_r", "pd_rd_i", "content-id", "ref_", "crid", "sprefix", "qid", "dib", "dib_tag"],
        "linkedin.com": ["trackingid", "refid", "lipi", "midtoken", "midsig", "trk", "trkemail"]
    ]

    /// host suffix, path prefix, parameter carrying the real destination
    private static let wrappers: [(host: String, path: String, param: String)] = [
        ("google.", "/url", "q"),
        ("google.", "/url", "url"),
        ("l.facebook.com", "/l.php", "u"),
        ("lm.facebook.com", "/l.php", "u"),
        ("l.messenger.com", "/l.php", "u"),
        ("l.instagram.com", "/", "u"),
        ("youtube.com", "/redirect", "q"),
        ("out.reddit.com", "/", "url"),
        ("linkedin.com", "/redir/redirect", "url"),
        ("steamcommunity.com", "/linkfilter", "url"),
        ("steamcommunity.com", "/linkfilter", "u"),
        ("t.umblr.com", "/redirect", "z"),
        ("slack-redir.net", "/link", "url"),
        ("disq.us", "/url", "url"),
        ("vk.com", "/away.php", "to"),
        ("duckduckgo.com", "/l/", "uddg"),
        ("bing.com", "/ck/a", "u")
    ]

    /// Returns a cleaned URL, or nil if nothing needed changing.
    static func clean(_ url: URL) -> URL? {
        var current = url
        var changed = false

        for _ in 0..<3 {
            if let unwrapped = unwrap(current) {
                current = unwrapped
                changed = true
            } else {
                break
            }
        }

        if let stripped = stripParams(current) {
            current = stripped
            changed = true
        }
        return changed ? current : nil
    }

    private static func unwrap(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased(),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = url.path

        // Google AMP viewer: https://www.google.com/amp/s/example.com/page
        if host.contains("google."), path.hasPrefix("/amp/s/") {
            let rest = String(path.dropFirst("/amp/s/".count))
            return URL(string: "https://" + rest)
        }

        for w in wrappers {
            let hostMatches = w.host.hasSuffix(".")
                ? host.contains(w.host) || host.hasPrefix(String(w.host.dropLast()))
                : (host == w.host || host.hasSuffix("." + w.host))
            guard hostMatches, path.hasPrefix(w.path),
                  var value = comps.queryItems?.first(where: { $0.name == w.param })?.value,
                  !value.isEmpty else { continue }

            // Bing encodes the target as "a1" + base64url.
            if host.hasSuffix("bing.com"), value.hasPrefix("a1") {
                var b64 = String(value.dropFirst(2))
                    .replacingOccurrences(of: "-", with: "+")
                    .replacingOccurrences(of: "_", with: "/")
                while b64.count % 4 != 0 { b64 += "=" }
                guard let data = Data(base64Encoded: b64), let decoded = String(data: data, encoding: .utf8) else { continue }
                value = decoded
            }
            // Disqus appends ":<hash>"
            if host.hasSuffix("disq.us"), let range = value.range(of: ":[A-Za-z0-9_-]+$", options: .regularExpression) {
                value.removeSubrange(range)
            }
            if let target = URL(string: value), let scheme = target.scheme?.lowercased(),
               scheme == "http" || scheme == "https", target.host != nil {
                return target
            }
        }
        return nil
    }

    private static func stripParams(_ url: URL) -> URL? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems, !items.isEmpty else { return nil }
        let base = DomainUtil.baseDomain(url.host ?? "")
        let extra = siteParams[base] ?? []

        let kept = items.filter { item in
            let name = item.name.lowercased()
            if name.hasPrefix("utm_") { return false }
            if trackingParams.contains(name) { return false }
            if extra.contains(name) { return false }
            return true
        }
        guard kept.count != items.count else { return nil }
        comps.queryItems = kept.isEmpty ? nil : kept
        return comps.url
    }
}
