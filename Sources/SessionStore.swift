import Foundation
import WebKit

/// Survives the app being killed in the background (common on real devices under
/// memory pressure) by saving the current URL + WKWebView interaction state
/// (scroll position, back/forward history, form state) and restoring it on
/// the next cold launch.
final class SessionStore {

    static let shared = SessionStore()

    private let urlKey = "com.stalloevan.undirect.session.url"
    private let interactionStateKey = "com.stalloevan.undirect.session.interactionState"

    private init() {}

    func save(url: URL?, interactionState: Any?) {
        let defaults = UserDefaults.standard
        defaults.set(url?.absoluteString, forKey: urlKey)

        // WKWebView.interactionState is typically backed by Data (or an
        // NSSecureCoding-compliant object); only persist it if it archives
        // cleanly so a restore failure can never crash the app.
        if let data = interactionState as? Data {
            defaults.set(data, forKey: interactionStateKey)
        } else if let interactionState,
                  let archived = try? NSKeyedArchiver.archivedData(withRootObject: interactionState, requiringSecureCoding: false) {
            defaults.set(archived, forKey: interactionStateKey)
        } else {
            defaults.removeObject(forKey: interactionStateKey)
        }
    }

    func restoreURL() -> URL? {
        guard let string = UserDefaults.standard.string(forKey: urlKey) else { return nil }
        return URL(string: string)
    }

    func restoreInteractionState() -> Any? {
        UserDefaults.standard.data(forKey: interactionStateKey)
    }

    func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: urlKey)
        defaults.removeObject(forKey: interactionStateKey)
    }
}
