import Foundation

/// Persists the set of domains that are exempt from redirect/popup blocking.
/// Policy is whitelist-based: blocking is ON for every domain EXCEPT the ones stored here.
final class WhitelistStore {

    static let shared = WhitelistStore()

    private let defaultsKey = "com.stalloevan.undirect.whitelist"
    private var domains: Set<String>

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        domains = Set(saved)
    }

    /// Normalizes a host for comparison: lowercase, strips a leading "www.".
    static func normalize(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix("www.") {
            h.removeFirst(4)
        }
        return h
    }

    func isWhitelisted(host: String?) -> Bool {
        guard let host else { return false }
        let normalized = Self.normalize(host)
        // A host is whitelisted if it matches exactly or is a subdomain of a whitelisted domain.
        return domains.contains(where: { normalized == $0 || normalized.hasSuffix("." + $0) })
    }

    func add(host: String) {
        domains.insert(Self.normalize(host))
        persist()
    }

    func remove(host: String) {
        domains.remove(Self.normalize(host))
        persist()
    }

    func all() -> [String] {
        domains.sorted()
    }

    private func persist() {
        UserDefaults.standard.set(Array(domains), forKey: defaultsKey)
    }
}
