import Foundation

struct FavoriteSite: Codable, Equatable {
    let urlString: String
    let title: String
}

/// Bookmarks the person explicitly saves. This is entirely separate from
/// WhitelistStore: favoriting a site must never grant it permission to
/// redirect or open pop-ups, and visiting/whitelisting a site must never
/// favorite it. Neither store ever calls into the other.
final class FavoritesStore {

    static let shared = FavoritesStore()
    static let didChange = Notification.Name("UndirectFavoritesDidChange")

    private let defaultsKey = "com.stalloevan.undirect.favorites"

    private init() {}

    /// Decoded once and kept in memory — this is read on every NTP refresh
    /// and page-menu build, and used to re-decode JSON each time.
    private var cache: [FavoriteSite]?

    func all() -> [FavoriteSite] {
        if let cache { return cache }
        let items = UserDefaults.standard.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode([FavoriteSite].self, from: $0) } ?? []
        cache = items
        return items
    }

    func isFavorite(url: URL) -> Bool {
        all().contains { $0.urlString == url.absoluteString }
    }

    /// Adds or removes `url` from favorites. Purely a bookmark list — does not
    /// touch WhitelistStore in either direction.
    func toggle(url: URL, title: String) {
        var items = all()
        if let index = items.firstIndex(where: { $0.urlString == url.absoluteString }) {
            items.remove(at: index)
        } else {
            items.append(FavoriteSite(urlString: url.absoluteString, title: title))
        }
        persist(items)
    }

    func remove(at index: Int) {
        var items = all()
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        persist(items)
    }

    private func persist(_ items: [FavoriteSite]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        cache = items
        UserDefaults.standard.set(data, forKey: defaultsKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func remove(urlString: String) {
        persist(all().filter { $0.urlString != urlString })
    }

    func move(from: Int, to: Int) {
        var items = all()
        guard items.indices.contains(from), items.indices.contains(to) else { return }
        let item = items.remove(at: from)
        items.insert(item, at: to)
        persist(items)
    }
}
