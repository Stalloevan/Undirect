import Foundation

/// Persists open (non-Tor) tabs so they survive iOS killing the app in the background.
/// Tor tabs are deliberately never written to disk.
final class SessionStore {

    static let shared = SessionStore()

    struct SavedTab: Codable {
        let id: UUID
        let url: String?
        let state: Data?
    }

    struct SavedSession: Codable {
        let tabs: [SavedTab]
        let selected: Int
    }

    private let key = "com.stalloevan.undirect.session.tabs"
    private let legacyURLKey = "com.stalloevan.undirect.session.url"
    private let legacyStateKey = "com.stalloevan.undirect.session.interactionState"

    private init() {}

    func save(tabs: [Tab], selected: Tab?) {
        let persistable = tabs.filter { !$0.isTor }
        let saved = persistable.map { tab -> SavedTab in
            SavedTab(id: tab.id, url: tab.url?.absoluteString, state: Self.archive(tab.webView.interactionState))
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
            return SavedSession(tabs: [SavedTab(id: UUID(), url: url, state: state)], selected: 0)
        }
        return nil
    }

    private static func archive(_ state: Any?) -> Data? {
        if let data = state as? Data { return data }
        guard let state else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false)
    }
}
