import UIKit
import AppIntents

// MARK: - Open URL

/// "Open in Undirect" — opens a URL in a normal new tab and brings the app
/// to the foreground, same delivery mechanism as OpenImmersiveIntent since
/// BrowserContainerViewController may not exist yet when the intent runs.
struct OpenURLIntent: AppIntent {
    static var title: LocalizedStringResource = "Open URL in Undirect"
    static var description = IntentDescription("Opens a URL in a new tab in Undirect.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "URL")
    var url: URL

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            OpenURLRequest.pending = OpenURLRequest.Pending(url: url, tor: false)
            NotificationCenter.default.post(name: OpenURLRequest.notification, object: nil)
        }
        return .result()
    }
}

/// "Open in Tor" — same as above, but the tab is routed through Tor
/// regardless of the default new-tab setting.
struct OpenTorURLIntent: AppIntent {
    static var title: LocalizedStringResource = "Open URL in Tor in Undirect"
    static var description = IntentDescription("Opens a URL in a new Tor tab in Undirect.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "URL")
    var url: URL

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            OpenURLRequest.pending = OpenURLRequest.Pending(url: url, tor: true)
            NotificationCenter.default.post(name: OpenURLRequest.notification, object: nil)
        }
        return .result()
    }
}

/// Hands a requested URL from a Shortcuts action over to the browser once
/// it's ready, same pattern as ImmersiveRequest.
enum OpenURLRequest {
    struct Pending { let url: URL; let tor: Bool }
    static var pending: Pending?
    static let notification = Notification.Name("UndirectOpenURLRequest")
}

// MARK: - New blank tab

/// "New Tab" — opens a blank tab (address bar focused), without needing a URL.
struct NewTabIntent: AppIntent {
    static var title: LocalizedStringResource = "New Tab in Undirect"
    static var description = IntentDescription("Opens a new blank tab in Undirect.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Use Tor", default: false)
    var tor: Bool

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NewTabRequest.pendingTor = tor
            NotificationCenter.default.post(name: NewTabRequest.notification, object: nil)
        }
        return .result()
    }
}

enum NewTabRequest {
    static var pendingTor: Bool?
    static let notification = Notification.Name("UndirectNewTabRequest")
}

// MARK: - Background actions (no need to bring the app to the foreground)

/// "Clear Browsing Data" — wipes all website data (cookies, cache, local
/// storage, etc.) for normal tabs. Tor tabs never persist data to begin
/// with, so there's nothing there to clear.
struct ClearBrowsingDataIntent: AppIntent {
    static var title: LocalizedStringResource = "Clear Browsing Data in Undirect"
    static var description = IntentDescription("Clears all website data — cookies, cache, and local storage — in Undirect.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                CookieGuard.shared.clearEverything { continuation.resume() }
            }
        }
        return .result()
    }
}

/// "New Tor Identity" — signals Tor for a fresh circuit (new exit node,
/// new identity as far as sites can tell), the same action available from
/// the in-app Tor menu.
struct NewTorIdentityIntent: AppIntent {
    static var title: LocalizedStringResource = "New Tor Identity in Undirect"
    static var description = IntentDescription("Requests a fresh Tor circuit in Undirect.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let ok = await withCheckedContinuation { continuation in
            TorManager.shared.newIdentity { success in continuation.resume(returning: success) }
        }
        guard ok else {
            throw UndirectIntentError.message("Tor isn't connected right now.")
        }
        return .result()
    }
}

// MARK: - Favorites

/// "Add Favorite" — bookmarks a URL without needing the app open.
struct AddFavoriteIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Favorite in Undirect"
    static var description = IntentDescription("Adds a URL to your Undirect favorites.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "URL")
    var url: URL

    @Parameter(title: "Title", default: "")
    var pageTitle: String

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            guard !FavoritesStore.shared.isFavorite(url: url) else { return }
            let title = pageTitle.isEmpty ? (url.host ?? url.absoluteString) : pageTitle
            FavoritesStore.shared.toggle(url: url, title: title)
        }
        return .result()
    }
}

/// "Get Favorites" — returns the saved favorite URLs, for use later in a
/// shortcut (e.g. picking one to open).
struct GetFavoritesIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Favorites from Undirect"
    static var description = IntentDescription("Returns your list of favorite URLs from Undirect.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<[URL]> {
        let urls = await MainActor.run {
            FavoritesStore.shared.all().compactMap { URL(string: $0.urlString) }
        }
        return .result(value: urls)
    }
}

// MARK: - Errors

enum UndirectIntentError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

// MARK: - Shortcuts catalog

struct UndirectShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenImmersiveIntent(),
            phrases: ["Open immersive in \(.applicationName)", "Open \(.applicationName) immersive"],
            shortTitle: "Open Immersive",
            systemImageName: "rectangle.fill.on.rectangle.fill"
        )
        AppShortcut(
            intent: OpenURLIntent(),
            phrases: ["Open a URL in \(.applicationName)"],
            shortTitle: "Open URL",
            systemImageName: "safari"
        )
        AppShortcut(
            intent: OpenTorURLIntent(),
            phrases: ["Open a URL in Tor in \(.applicationName)"],
            shortTitle: "Open in Tor",
            systemImageName: "network.badge.shield.half.filled"
        )
        AppShortcut(
            intent: NewTabIntent(),
            phrases: ["New tab in \(.applicationName)"],
            shortTitle: "New Tab",
            systemImageName: "plus.square"
        )
        AppShortcut(
            intent: ClearBrowsingDataIntent(),
            phrases: ["Clear browsing data in \(.applicationName)"],
            shortTitle: "Clear Browsing Data",
            systemImageName: "trash"
        )
        AppShortcut(
            intent: NewTorIdentityIntent(),
            phrases: ["New Tor identity in \(.applicationName)"],
            shortTitle: "New Tor Identity",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: AddFavoriteIntent(),
            phrases: ["Add a favorite in \(.applicationName)"],
            shortTitle: "Add Favorite",
            systemImageName: "star"
        )
        AppShortcut(
            intent: GetFavoritesIntent(),
            phrases: ["Get favorites from \(.applicationName)"],
            shortTitle: "Get Favorites",
            systemImageName: "star.fill"
        )
    }
}
