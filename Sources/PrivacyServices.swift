import UIKit
import WebKit
import Network

// MARK: - Cookies

/// Cookie policy:
/// - third-party cookies are blocked outright (content rule, see ContentBlocker)
/// - known analytics / ad identifier cookies are overwritten with random values
///   after every page load, so they can't follow you between visits
/// - site data for sites you haven't logged into is wiped (tab close / leaving
///   the app, configurable). Sites where you submitted a password are detected
///   automatically and kept, so logins survive.
final class CookieGuard {
    static let shared = CookieGuard()

    let keptLogins = DomainSetStore(key: "com.stalloevan.undirect.keptLogins")

    private static let analyticsPrefixes = [
        "_ga", "_gid", "_gat", "_gcl_", "_fbp", "_fbc", "_uetsid", "_uetvid", "_hjsessionuser", "_hjid",
        "_hjsession", "_clck", "_clsk", "__utm", "ajs_anonymous_id", "_pin_unauth", "_tt_enable_cookie",
        "_ttp", "mp_", "amplitude_id", "_scid", "_rdt_uuid", "_derived_epik", "_parsely_visitor",
        "_cs_id", "s_vi", "s_fid", "amcv_", "__qca", "_lr_", "_ym_uid", "_ym_d", "_pk_id", "_pk_ses",
        "__adroll", "_kuid_", "__gads", "__gpi", "_twitter_sess_ad", "personalization_id", "muid"
    ]

    private init() {}

    private static func isAnalytics(_ name: String) -> Bool {
        let n = name.lowercased()
        return analyticsPrefixes.contains { n.hasPrefix($0) }
    }

    func spoofAnalyticsCookies(in store: WKHTTPCookieStore) {
        guard Settings.shared.spoofAnalyticsCookies else { return }
        store.getAllCookies { cookies in
            var changed = 0
            for cookie in cookies where Self.isAnalytics(cookie.name) {
                // Leave our own spoofed values alone until the site overwrites them.
                if cookie.value.hasPrefix("u.") { continue }
                var props = cookie.properties ?? [:]
                props[.value] = "u." + Self.randomString(length: max(12, cookie.value.count))
                if let fresh = HTTPCookie(properties: props) {
                    store.setCookie(fresh)
                    changed += 1
                }
            }
            BlockStats.shared.increment(.cookies, by: changed)
        }
    }

    /// Removes stored data for every site that isn't a kept login and isn't open in `activeHosts`.
    func cleanUp(activeHosts: [String]) {
        let active = Set(activeHosts.map { DomainUtil.baseDomain($0) })
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let doomed = records.filter { record in
                let name = record.displayName.lowercased()
                return !self.keptLogins.contains(host: name) && !active.contains(DomainUtil.baseDomain(name))
            }
            guard !doomed.isEmpty else { return }
            store.removeData(ofTypes: types, for: doomed) {
                BlockStats.shared.increment(.cookies, by: doomed.count)
            }
        }
    }

    func clearEverything(completion: @escaping () -> Void) {
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast,
            completionHandler: completion
        )
    }

    private static func randomString(length: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}

// MARK: - Element hiding

final class ElementHideStore {
    static let shared = ElementHideStore()
    static let didChange = Notification.Name("UndirectElementRulesDidChange")

    private let key = "com.stalloevan.undirect.hiddenElements"
    private var rules: [String: [String]]

    private init() {
        rules = (UserDefaults.standard.dictionary(forKey: key) as? [String: [String]]) ?? [:]
    }

    func all() -> [String: [String]] { rules }

    func add(selector: String, host: String) {
        let base = DomainUtil.baseDomain(host)
        var list = rules[base] ?? []
        guard !list.contains(selector) else { return }
        list.append(selector)
        rules[base] = list
        persist()
    }

    func removeAll(for base: String) {
        rules[base] = nil
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(rules, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Document-start script that hides this site's saved elements.
    func scriptSource() -> String {
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("{}".utf8)
        let json = String(decoding: data, as: UTF8.self)
        return """
        (function () {
          var M = \(json);
          var h = location.hostname.replace(/^www\\./, '');
          var sels = [];
          for (var k in M) { if (h === k || h.endsWith('.' + k)) sels = sels.concat(M[k]); }
          if (!sels.length) return;
          var css = sels.map(function (s) { return s + '{display:none !important}'; }).join('\\n');
          function inject() {
            var st = document.createElement('style');
            st.textContent = css;
            (document.head || document.documentElement).appendChild(st);
          }
          if (document.documentElement) inject();
          else document.addEventListener('DOMContentLoaded', inject);
        })();
        """
    }
}

// MARK: - Favicons

// MARK: - Edge color

extension UIColor {
    func blended(with other: UIColor, amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = max(0, min(1, amount))
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: a1 + (a2 - a1) * t)
    }
}

extension UIImage {
    /// The average color of this image's outer border pixels — used to bleed
    /// a favicon's own edge color out to fill its tab/row, rather than the
    /// icon sitting on a flat, unrelated background.
    /// The last non-transparent pixel found while tracing the image's outer
    /// border (clockwise from the top-left) — a real, specific pixel color
    /// rather than a blend of every border pixel, which tended to wash out
    /// into a muddy average that didn't match anything actually in the icon.
    func edgeColor() -> UIColor {
        let side = 12
        guard let cgImage = cgImage else { return Theme.field }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Theme.field }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var perimeter: [(Int, Int)] = []
        for x in 0..<side { perimeter.append((x, 0)) }
        for y in 1..<side { perimeter.append((side - 1, y)) }
        for x in stride(from: side - 2, through: 0, by: -1) { perimeter.append((x, side - 1)) }
        for y in stride(from: side - 2, through: 1, by: -1) { perimeter.append((0, y)) }

        var last: UIColor?
        for (x, y) in perimeter {
            let o = (y * side + x) * 4
            let a = Double(pixels[o + 3]) / 255.0
            guard a > 0.2 else { continue }
            let r = min(1, Double(pixels[o]) / 255.0 / a)
            let g = min(1, Double(pixels[o + 1]) / 255.0 / a)
            let b = min(1, Double(pixels[o + 2]) / 255.0 / a)
            last = UIColor(red: r, green: g, blue: b, alpha: 1)
        }
        return last ?? Theme.field
    }
}

final class FaviconStore {
    static let shared = FaviconStore()

    private var memory: [String: UIImage] = [:]
    private let directory: URL
    private let session: URLSession

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        session = URLSession(configuration: config)
    }

    private func key(_ host: String) -> String { DomainUtil.normalize(host) }

    func cached(host: String?) -> UIImage? {
        guard let host else { return nil }
        let k = key(host)
        if let image = memory[k] { return image }
        let file = directory.appendingPathComponent(k + ".png")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memory[k] = image
            return image
        }
        return nil
    }

    /// Fetches over a plain ephemeral session. Never call this for Tor tabs.
    func fetch(host: String, hint: URL?, completion: @escaping (UIImage?) -> Void) {
        if let image = cached(host: host) { completion(image); return }
        var candidates: [URL] = []
        if let hint { candidates.append(hint) }
        if let u = URL(string: "https://\(host)/apple-touch-icon.png") { candidates.append(u) }
        if let u = URL(string: "https://\(host)/favicon.ico") { candidates.append(u) }
        tryNext(candidates, host: host, completion: completion)
    }

    private func tryNext(_ urls: [URL], host: String, completion: @escaping (UIImage?) -> Void) {
        guard let url = urls.first else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        session.dataTask(with: url) { [weak self] data, response, _ in
            guard let self else { return }
            if let data, (response as? HTTPURLResponse)?.statusCode ?? 0 < 400,
               let image = UIImage(data: data), image.size.width >= 16 {
                let resized = Self.normalize(image)
                DispatchQueue.main.async {
                    self.memory[self.key(host)] = resized
                    if let png = resized.pngData() {
                        try? png.write(to: self.directory.appendingPathComponent(self.key(host) + ".png"))
                    }
                    completion(resized)
                }
            } else {
                self.tryNext(Array(urls.dropFirst()), host: host, completion: completion)
            }
        }.resume()
    }

    private static func normalize(_ image: UIImage) -> UIImage {
        let size = CGSize(width: 64, height: 64)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    static func monogram(for host: String?, tor: Bool) -> UIImage {
        let size = CGSize(width: 64, height: 64)
        let letter = host.map { String(DomainUtil.normalize($0).prefix(1)).uppercased() } ?? "+"
        let seed = (host ?? "").unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 3600 }
        let hue = CGFloat(seed % 360) / 360
        let color = tor ? Theme.tor : UIColor(hue: hue, saturation: 0.35, brightness: 0.55, alpha: 1)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 14).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 30, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
            let text = letter as NSString
            let t = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (size.width - t.width) / 2, y: (size.height - t.height) / 2), withAttributes: attrs)
            _ = ctx
        }
    }
}

// MARK: - Preloading

/// Warms WebKit's HTTP cache for your top favorites in the background, so
/// opening them is near-instant. Only runs on unmetered Wi-Fi, never in Low
/// Power Mode, and uses the same ad/tracker rules as normal tabs.
final class FavoritePreloader: NSObject, WKNavigationDelegate {
    static let shared = FavoritePreloader()

    private var webView: WKWebView?
    private var queue: [URL] = []
    private var timeout: DispatchWorkItem?
    private let monitor = NWPathMonitor()
    private var pathIsCheap = false

    private override init() {
        super.init()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.pathIsCheap = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    func start(after delay: TimeInterval = 4) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.webView == nil,
                  Settings.shared.preloadFavorites,
                  !ProcessInfo.processInfo.isLowPowerModeEnabled,
                  self.pathIsCheap else { return }
            self.queue = FavoritesStore.shared.all().prefix(4).compactMap { URL(string: $0.urlString) }
            guard !self.queue.isEmpty else { return }
            let config = WebEngine.makeConfiguration(tor: false)
            ContentBlocker.shared.apply(to: config.userContentController, paused: false)
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 667), configuration: config)
            wv.navigationDelegate = self
            self.webView = wv
            self.loadNext()
        }
    }

    private func loadNext() {
        timeout?.cancel()
        guard let wv = webView, !queue.isEmpty else { finish(); return }
        let url = queue.removeFirst()
        wv.load(URLRequest(url: url))
        let work = DispatchWorkItem { [weak self] in self?.loadNext() }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func finish() {
        timeout?.cancel()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(scheme == "http" || scheme == "https" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loadNext() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loadNext() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loadNext() }
}
