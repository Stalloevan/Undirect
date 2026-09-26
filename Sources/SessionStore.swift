import Foundation
import WebKit

/// Persists open tabs so they survive the app being closed or killed in the
/// background. Tor tabs keep only their current address — never their
/// history or page state — and reopen through Tor.
final class SessionStore {

    static let shared = SessionStore()

    struct SavedTab: Codable {
        let id: UUID
        let url: String?
        let state: Data?
        /// Optional so sessions saved by older versions still decode.
        let tor: Bool?
    }

    struct SavedSession: Codable {
        let tabs: [SavedTab]
        let selected: Int
    }

    private let key = "com.stalloevan.undirect.session.tabs"
    private let legacyURLKey = "com.stalloevan.undirect.session.url"
    private let legacyStateKey = "com.stalloevan.undirect.session.interactionState"

    private init() {}

    /// What the last save looked like (tab ids, addresses, selection), so the
    /// frequent debounced saves during page loads can skip re-archiving every
    /// tab's history when nothing that matters has changed.
    private var lastSignature: String?

    func save(tabs: [Tab], selected: Tab?, onlyIfChanged: Bool = false) {
        let persistable = tabs
        var parts: [String] = []
        for tab in persistable {
            let url = tab.url?.absoluteString ?? ""
            let historyCount = tab.webView.backForwardList.backList.count
            parts.append(tab.id.uuidString + "|" + url + "|" + String(historyCount))
        }
        let selectedID = selected?.id.uuidString ?? "-"
        let signature = parts.joined(separator: "\n") + "#" + selectedID
        if onlyIfChanged, signature == lastSignature { return }
        lastSignature = signature
        let saved = persistable.map { tab -> SavedTab in
            SavedTab(id: tab.id, url: tab.url?.absoluteString,
                     state: tab.isTor ? nil : Self.archive(tab.webView.interactionState),
                     tor: tab.isTor)
        }
        let index = selected.flatMap { sel in persistable.firstIndex { $0 === sel } } ?? max(0, persistable.count - 1)
        if let data = try? JSONEncoder().encode(SavedSession(tabs: saved, selected: index)) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func restore() -> SavedSession? {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key),
           let session = try? JSONDecoder().decode(SavedSession.self, from: data) {
            return session
        }
        // Migrate the single-page session from v1.x.
        if let url = defaults.string(forKey: legacyURLKey) {
            let state = defaults.data(forKey: legacyStateKey)
            defaults.removeObject(forKey: legacyURLKey)
            defaults.removeObject(forKey: legacyStateKey)
            return SavedSession(tabs: [SavedTab(id: UUID(), url: url, state: state, tor: false)], selected: 0)
        }
        return nil
    }

    func clear() {
        lastSignature = nil
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func archive(_ state: Any?) -> Data? {
        if let data = state as? Data { return data }
        guard let state else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false)
    }
}
