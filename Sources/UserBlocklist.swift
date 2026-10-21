import Foundation

/// The person's own additions to ad & tracker blocking:
///  - `blocked`: domains to block on top of the built-in lists.
///  - `allowed`: domains to let through even though a built-in list blocks them.
///
/// A domain covers its subdomains. Blocking and allowing the same name cancel
/// each other out, so the newest choice always wins.
final class UserBlocklist {

    static let shared = UserBlocklist()
    static let didChange = Notification.Name("UndirectUserBlocklistDidChange")

    enum Outcome: Equatable {
        case added(String)
        case alreadyThere(String)
        case invalid
    }

    private let blockedKey = "s.userBlockedDomains"
    private let allowedKey = "s.userAllowedDomains"
    private(set) var blocked: [String]
    private(set) var allowed: [String]

    private init() {
        let defaults = UserDefaults.standard
        blocked = Self.sanitized(defaults.stringArray(forKey: blockedKey) ?? [])
        allowed = Self.sanitized(defaults.stringArray(forKey: allowedKey) ?? [])
    }

    // MARK: Parsing

    /// Accepts "example.com", "https://www.example.com/path?x", "*.example.com"
    /// and returns the lowercase hostname, or nil if it isn't a usable domain.
    static func clean(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if let at = text.lastIndex(of: "@"), !(text[..<at].contains("/")) { text = String(text[text.index(after: at)...]) }
        if let end = text.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { text = String(text[..<end]) }
        if let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        while text.hasPrefix("*.") || text.hasPrefix(".") { text.removeFirst(text.hasPrefix("*.") ? 2 : 1) }
        while text.hasSuffix(".") { text.removeLast() }
        guard text.count <= 253, text.contains(".") else { return nil }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return nil }
            for scalar in label.unicodeScalars {
                let ok = (scalar.value >= 0x61 && scalar.value <= 0x7A) || (scalar.value >= 0x30 && scalar.value <= 0x39)
                    || scalar == "-" || scalar == "_"
                if !ok { return nil }
            }
        }
        return text
    }

    private static func sanitized(_ list: [String]) -> [String] {
        Array(Set(list.compactMap { clean($0) })).sorted()
    }

    /// `entry` is `host` itself or one of its parent domains, or the other way round.
    static func related(_ a: String, _ b: String) -> Bool {
        a == b || a.hasSuffix("." + b) || b.hasSuffix("." + a)
    }

    // MARK: Changes

    @discardableResult
    func block(_ input: String) -> Outcome {
        guard let host = Self.clean(input) else { return .invalid }
        // Choosing to block cancels any earlier "allow" for the same name.
        let clearedAllow = allowed.filter { Self.related($0, host) }
        allowed.removeAll { Self.related($0, host) }
        if blocked.contains(host) {
            if !clearedAllow.isEmpty { commit() }
            return .alreadyThere(host)
        }
        blocked = (blocked + [host]).sorted()
        commit()
        return .added(host)
    }

    @discardableResult
    func allow(_ input: String) -> Outcome {
        guard let host = Self.clean(input) else { return .invalid }
        // Allowing a name also drops blocks of your own that would still catch it.
        let clearedBlocks = blocked.filter { Self.related($0, host) }
        blocked.removeAll { Self.related($0, host) }
        if allowed.contains(host) {
            if !clearedBlocks.isEmpty { commit() }
            return .alreadyThere(host)
        }
        allowed = (allowed + [host]).sorted()
        commit()
        return .added(host)
    }

    func removeBlocked(_ host: String) {
        guard blocked.contains(host) else { return }
        blocked.removeAll { $0 == host }
        commit()
    }

    func removeAllowed(_ host: String) {
        guard allowed.contains(host) else { return }
        allowed.removeAll { $0 == host }
        commit()
    }

    private func commit() {
        let defaults = UserDefaults.standard
        defaults.set(blocked, forKey: blockedKey)
        defaults.set(allowed, forKey: allowedKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        ContentBlocker.shared.rebuild()
    }
}
