import Foundation

enum SiteCategory: String, CaseIterable {
    case adult = "porn"
    case gambling
    case scam
    case fraud
    case phishing
    case malware

    var label: String {
        switch self {
        case .adult: return "adult content"
        case .gambling: return "gambling"
        case .scam: return "known scam domain"
        case .fraud: return "known fraud domain"
        case .phishing: return "known phishing domain"
        case .malware: return "known malware domain"
        }
    }

    /// How hard this category should pull the trust score down.
    var penalty: Int {
        switch self {
        case .phishing: return 55
        case .malware: return 55
        case .fraud: return 40
        case .scam: return 40
        case .gambling: return 15
        case .adult: return 15
        }
    }
}

/// A local, bundled index built from The Block List Project's categorized
/// domain lists — sampled down from the full lists (which run into the
/// millions of entries for some categories) to keep this fast and small
/// while still giving representative coverage. Looked up entirely on-device;
/// nothing about a URL you're viewing a trust score for is ever sent
/// anywhere to check it.
enum SiteReputationIndex {
    private static let domainsByCategory: [SiteCategory: Set<String>] = {
        var result: [SiteCategory: Set<String>] = [:]
        for category in SiteCategory.allCases {
            guard let url = Bundle.main.url(forResource: "reputation-\(category.rawValue)", withExtension: "txt"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let domains = text.split(whereSeparator: \.isNewline).map { DomainUtil.normalize(String($0)) }
            result[category] = Set(domains)
        }
        return result
    }()

    /// Every category `host` (or a parent domain of it) appears under.
    static func categories(for host: String?) -> [SiteCategory] {
        guard let host, !host.isEmpty else { return [] }
        var matches: [SiteCategory] = []
        for category in SiteCategory.allCases {
            guard let set = domainsByCategory[category] else { continue }
            var h = DomainUtil.normalize(host)
            while true {
                if set.contains(h) { matches.append(category); break }
                guard let dot = h.firstIndex(of: ".") else { break }
                h = String(h[h.index(after: dot)...])
                if !h.contains(".") { break }
            }
        }
        return matches
    }
}
