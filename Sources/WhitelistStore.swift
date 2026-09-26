import Foundation

/// Persists the set of domains that are exempt from redirect/popup blocking.
/// Policy is whitelist-based: blocking is ON for every domain EXCEPT the ones stored here.
final class WhitelistStore {

    static let shared = WhitelistStore()
    static let didChange = Notification.Name("UndirectWhitelistDidChange")

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

    /// Removes every entry that makes `host` trusted — the host itself and
    /// any parent domain. (Removing only the exact host left a site trusted
    /// when the trust came from its parent, so "Untrust" did nothing.)
    func remove(host: String) {
        let h = Self.normalize(host)
        domains = domains.filter { !(h == $0 || h.hasSuffix("." + $0)) }
        persist()
    }

    func all() -> [String] {
        domains.sorted()
    }

    private func persist() {
        UserDefaults.standard.set(Array(domains), forKey: defaultsKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
