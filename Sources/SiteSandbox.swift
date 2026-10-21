import Foundation
import WebKit
import CryptoKit

/// Keeps every site apart from every other site.
///
/// - Each normal tab has its own private storage (cookies, local storage,
///   caches). One tab can never read what another tab's sites stored. The
///   storage is deleted when the tab closes.
/// - Each Tor tab has its own in-memory storage that goes through Tor.
/// - Sites where you chose to stay logged in (Kept Logins) and sites that
///   passed a Cloudflare check get one saved store of their own, reused by
///   every tab that opens that site. Only that site's data is kept in it.
///
/// WebKit fixes a web view's storage when the view is created, so a tab's
/// storage is chosen from the address it starts on. Cookies for kept sites are
/// also copied from a private tab into the site's saved store when the tab
/// closes or the app goes to the background.
enum SiteSandbox {

    /// Sites whose Cloudflare clearance is remembered (kept logins are in CookieGuard.keptLogins).
    static let clearedSites = DomainSetStore(key: "com.stalloevan.undirect.clearedSites")

    private static let migrationKey = "s.sandboxMigrated"

    // MARK: Which store

    private static func derivedID(_ name: String) -> UUID {
        let d = Array(SHA256.hash(data: Data(("undirect.store." + name).utf8)))
        return UUID(uuid: (d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
                           d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]))
    }

    static func siteStoreID(_ base: String) -> UUID { derivedID("site." + base) }
    static func appStoreID(_ appID: String) -> UUID { derivedID("app." + appID) }

    static func tabStore(_ id: UUID) -> WKWebsiteDataStore { WKWebsiteDataStore(forIdentifier: id) }
    static func siteStore(_ base: String) -> WKWebsiteDataStore { WKWebsiteDataStore(forIdentifier: siteStoreID(base)) }
    static func appStore(_ appID: String) -> WKWebsiteDataStore { WKWebsiteDataStore(forIdentifier: appStoreID(appID)) }

    /// With cookie cleanup set to Never every site keeps its data.
    private static var keepsEverything: Bool { Settings.shared.cookieCleanup == .never }

    static func shouldKeep(base: String) -> Bool {
        keepsEverything || CookieGuard.shared.keptLogins.contains(host: base) || clearedSites.contains(host: base)
    }

    /// The saved site store a tab starting on `host` should use, if any.
    static func persistentBase(forHost host: String?) -> String? {
        guard let host, !host.isEmpty, host.contains("."), !host.hasSuffix(".onion") else { return nil }
        let base = DomainUtil.baseDomain(host)
        return shouldKeep(base: base) ? base : nil
    }

    // MARK: Keeping what should be kept

    /// Copies the cookies worth keeping (kept logins, Cloudflare clearance)
    /// from a tab's private store into each site's saved store.
    static func syncKept(from store: WKWebsiteDataStore, completion: (() -> Void)? = nil) {
        store.httpCookieStore.getAllCookies { cookies in
            let clearanceOn = Settings.shared.cloudflareFriendly
            var byBase: [String: [HTTPCookie]] = [:]
            for cookie in cookies {
                let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let base = DomainUtil.baseDomain(domain)
                if shouldKeepEverything(base) {
                    byBase[base, default: []].append(cookie)
                } else if clearanceOn && CookieGuard.isClearanceCookie(cookie.name) {
                    byBase[base, default: []].append(cookie)
                    if !clearedSites.contains(host: base) { clearedSites.add(host: base) }
                }
            }
            guard !byBase.isEmpty else { completion?(); return }
            let group = DispatchGroup()
            for (base, list) in byBase {
                let destination = siteStore(base).httpCookieStore
                for cookie in list {
                    group.enter()
                    destination.setCookie(cookie) { group.leave() }
                }
            }
            group.notify(queue: .main) { completion?() }
        }
    }

    /// Copies a kept site's saved cookies into a private tab's store before it loads the site.
    static func restoreKept(base: String, into store: WKWebsiteDataStore, then proceed: @escaping () -> Void) {
        siteStore(base).httpCookieStore.getAllCookies { cookies in
            let own = cookies.filter {
                DomainUtil.baseDomain($0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) == base
            }
            guard !own.isEmpty else { proceed(); return }
            let group = DispatchGroup()
            for cookie in own {
                group.enter()
                store.httpCookieStore.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .main, execute: proceed)
        }
    }

    private static func shouldKeepEverything(_ base: String) -> Bool {
        keepsEverything || CookieGuard.shared.keptLogins.contains(host: base)
    }

    // MARK: Ending a tab

    /// Called when a tab is closed. `siteBase` is set when the tab used a saved
    /// site store, and `stillShared` says another open tab uses the same store.
    static func retire(store: WKWebsiteDataStore, tabID: UUID, siteBase: String?, stillShared: Bool) {
        if let siteBase {
            guard !stillShared, !keepsEverything else { return }
            scrub(siteStore: store, base: siteBase)
            return
        }
        syncKept(from: store) {
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { removeStore(tabID, attempt: 0) }
            }
        }
    }

    private static func removeStore(_ id: UUID, attempt: Int) {
        WKWebsiteDataStore.remove(forIdentifier: id) { error in
            // Fails while a web view still holds it; the launch sweep finishes the job.
            if error != nil, attempt < 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { removeStore(id, attempt: attempt + 1) }
            }
        }
    }

    /// A saved site store only keeps its own site: anything another site
    /// wrote into it is removed, and a site kept only for its Cloudflare
    /// clearance keeps nothing but that cookie.
    private static func scrub(siteStore store: WKWebsiteDataStore, base: String) {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let foreign = records.filter { DomainUtil.baseDomain($0.displayName) != base }
            let own = records.filter { DomainUtil.baseDomain($0.displayName) == base }
            if !foreign.isEmpty { store.removeData(ofTypes: types, for: foreign) {} }
            guard !CookieGuard.shared.keptLogins.contains(host: base) else { return }
            var rest = types
            rest.remove(WKWebsiteDataTypeCookies)
            if !own.isEmpty { store.removeData(ofTypes: rest, for: own) {} }
            let cookies = store.httpCookieStore
            cookies.getAllCookies { all in
                for cookie in all where !CookieGuard.isClearanceCookie(cookie.name) { cookies.delete(cookie) }
            }
        }
    }

    // MARK: Cleaning up

    /// Removes stores that no longer belong to anything: tabs that were
    /// closed while the app was killed, and sites no longer kept.
    static func collectGarbage(openTabIDs: @escaping () -> Set<UUID>) {
        // With cleanup set to Never, site stores hold everything and can't be told apart by id.
        guard !keepsEverything else { return }
        var keep = Set<UUID>()
        for pwa in PWAStore.shared.all() { keep.insert(appStoreID(pwa.id)) }
        for base in CookieGuard.shared.keptLogins.all() + clearedSites.all() { keep.insert(siteStoreID(base)) }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.fetchAllDataStoreIdentifiers { ids in
            DispatchQueue.main.async {
                // Read the open tabs now, so a tab opened while this ran is never swept.
                let alive = keep.union(openTabIDs())
                for id in ids where !alive.contains(id) {
                    tabStore(id).removeData(ofTypes: types, modifiedSince: .distantPast) {
                        removeStore(id, attempt: 1)
                    }
                }
            }
        }
    }

    /// One time, when sandboxing first runs: carries logins and Cloudflare
    /// clearance from the old shared store into the per-site stores, then
    /// empties the old store.
    static func migrateLegacyStoreIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }
        defaults.set(true, forKey: migrationKey)
        let legacy = WKWebsiteDataStore.default()
        legacy.httpCookieStore.getAllCookies { cookies in
            var byBase: [String: [HTTPCookie]] = [:]
            for cookie in cookies {
                let base = DomainUtil.baseDomain(cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
                if CookieGuard.shared.keptLogins.contains(host: base) {
                    byBase[base, default: []].append(cookie)
                } else if CookieGuard.isClearanceCookie(cookie.name) {
                    byBase[base, default: []].append(cookie)
                    if !clearedSites.contains(host: base) { clearedSites.add(host: base) }
                }
            }
            let group = DispatchGroup()
            for (base, list) in byBase {
                let destination = siteStore(base).httpCookieStore
                for cookie in list {
                    group.enter()
                    destination.setCookie(cookie) { group.leave() }
                }
            }
            group.notify(queue: .main) {
                legacy.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
            }
        }
    }

    /// Removes the data of every store: the old shared one, every tab's and every site's.
    static func clearAll(completion: @escaping () -> Void) {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let group = DispatchGroup()
        group.enter()
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) { group.leave() }
        group.enter()
        WKWebsiteDataStore.fetchAllDataStoreIdentifiers { ids in
            for id in ids {
                group.enter()
                tabStore(id).removeData(ofTypes: types, modifiedSince: .distantPast) { group.leave() }
            }
            group.leave()
        }
        group.notify(queue: .main) {
            for base in clearedSites.all() { clearedSites.remove(host: base) }
            completion()
        }
    }
}
