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
        /// The tab stack this tab belonged to (UUID string), if any.
        let stack: String?
        /// Shown in the tab bar until the tab is opened (tabs load lazily).
        let title: String?
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
            // History only for a page that has actually loaded (or the saved
            // history of a tab not opened yet) — never a blank web view's
            // empty state, which would restore as an empty tab.
            let state: Data? = tab.isTor ? nil
                : tab.isDeferred ? tab.deferredState
                : tab.webView.url == nil ? nil
                : Self.archive(tab.webView.interactionState)
            return SavedTab(id: tab.id, url: tab.url?.absoluteString,
                     state: state,
                     tor: tab.isTor, stack: tab.stackID?.uuidString,
                     title: (tab.isTor || tab.url == nil) ? nil : tab.title)
        }
        let index = selected.flatMap { sel in persistable.firstIndex { $0 === sel } } ?? max(0, persistable.count - 1)
        // Encoding every tab's history and writing it out happens off the
        // main thread; only reading the web views' state has to happen here.
        let key = self.key
        writeQueue.async {
            if let data = try? JSONEncoder().encode(SavedSession(tabs: saved, selected: index)) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    private let writeQueue = DispatchQueue(label: "undirect.session.write", qos: .utility)

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
            return SavedSession(tabs: [SavedTab(id: UUID(), url: url, state: state, tor: false, stack: nil, title: nil)], selected: 0)
        }
        return nil
    }

    /// Whether the saved session includes a Tor tab (decides whether to start
    /// Tor first thing at launch).
    func hasTorTabs() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: key),
              let session = try? JSONDecoder().decode(SavedSession.self, from: data) else { return false }
        return session.tabs.contains { $0.tor == true }
    }

    func clear() {
        lastSignature = nil
        let key = self.key
        writeQueue.async { UserDefaults.standard.removeObject(forKey: key) }
    }

    private static func archive(_ state: Any?) -> Data? {
        if let data = state as? Data { return data }
        guard let state else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false)
    }
}
