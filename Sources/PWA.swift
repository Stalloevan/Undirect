import UIKit

/// A web app the person has "installed". iOS won't let a sideloaded app place
/// a real icon on the home screen (that needs the system Add to Home Screen
/// capability), so an installed PWA lives in Undirect: it opens in a clean,
/// standalone, app-like window (no address bar), remembers its own scope, and
/// gets a generated icon in the same spirit as a Shortcuts icon.
struct InstalledPWA: Codable, Equatable {
    let id: String
    let name: String
    let startURL: String
    let scope: String
    let themeColorHex: String?
    let backgroundColorHex: String?
    /// Base64 PNG of a fetched manifest/apple-touch icon, if we got one.
    let iconPNGBase64: String?
    /// Seed for the generated fallback icon, so it stays stable per app.
    let iconSeed: Int

    var startURLValue: URL? { URL(string: startURL) }

    func inScope(_ url: URL) -> Bool {
        guard let scopeURL = URL(string: scope), let host = url.host, let scopeHost = scopeURL.host,
              host == scopeHost else { return false }
        return url.path.hasPrefix(scopeURL.path) || scopeURL.path == "/" || scopeURL.path.isEmpty
    }
}

/// Parsed from a page's <link rel="manifest"> plus apple-* meta tags.
struct WebAppManifest {
    var name: String
    var startURL: URL
    var scope: URL
    var display: String
    var themeColorHex: String?
    var backgroundColorHex: String?
    var iconURLs: [URL]

    /// A site is "installable" when it declares standalone/fullscreen display,
    /// the same bar iOS uses for showing an install affordance.
    var isInstallable: Bool { display == "standalone" || display == "fullscreen" || display == "minimal-ui" }
}

final class PWAStore {
    static let shared = PWAStore()
    static let didChange = Notification.Name("UndirectPWADidChange")

    private let key = "com.stalloevan.undirect.pwas"

    private init() {}

    func all() -> [InstalledPWA] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([InstalledPWA].self, from: data) else { return [] }
        return items
    }

    func isInstalled(startURL: URL) -> Bool {
        let id = Self.identifier(for: startURL)
        return all().contains { $0.id == id }
    }

    func install(_ pwa: InstalledPWA) {
        var items = all().filter { $0.id != pwa.id }
        items.append(pwa)
        persist(items)
    }

    func remove(id: String) {
        persist(all().filter { $0.id != id })
    }

    private func persist(_ items: [InstalledPWA]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    static func identifier(for startURL: URL) -> String {
        (startURL.host ?? "") + startURL.path
    }
}

/// Generates app icons for installed PWAs, in the spirit of the icons the
/// iOS Shortcuts app produces: a colored rounded-rect tile with a glyph or
/// monogram. Prefers the site's real icon when one was fetched; otherwise
/// builds a tile from the app's name and theme color.
enum PWAIconFactory {

    static func icon(for pwa: InstalledPWA, size: CGFloat = 120) -> UIImage {
        if let base64 = pwa.iconPNGBase64, let data = Data(base64Encoded: base64), let image = UIImage(data: data) {
            return roundedTile(size: size, seed: pwa.iconSeed, themeHex: pwa.themeColorHex) { rect in
                // Fit the real icon inside a themed tile with a little padding.
                let inset = rect.insetBy(dx: rect.width * 0.14, dy: rect.height * 0.14)
                image.draw(in: inset)
            }
        }
        return generated(name: pwa.name, seed: pwa.iconSeed, themeHex: pwa.themeColorHex, size: size)
    }

    static func generated(name: String, seed: Int, themeHex: String?, size: CGFloat = 120) -> UIImage {
        let letters = monogram(from: name)
        return roundedTile(size: size, seed: seed, themeHex: themeHex) { rect in
            let fontSize = size * (letters.count > 1 ? 0.4 : 0.5)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
            let text = letters as NSString
            let textSize = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attrs)
        }
    }

    private static func roundedTile(size: CGFloat, seed: Int, themeHex: String?, draw: (CGRect) -> Void) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        return UIGraphicsImageRenderer(size: rect.size).image { ctx in
            let base = themeHex.flatMap(UIColor.init(hex:)) ?? paletteColor(seed: seed)
            // A soft top-to-bottom gradient, like the Shortcuts tiles.
            let top = base.adjusted(brightness: 1.12)
            let bottom = base.adjusted(brightness: 0.82)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: size * 0.225)
            path.addClip()
            let colors = [top.cgColor, bottom.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: size), options: [])
            } else {
                base.setFill(); path.fill()
            }
            draw(rect)
        }
    }

    private static func monogram(from name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).filter { !$0.isEmpty }
        if words.count >= 2 {
            return String(words[0].first!).uppercased() + String(words[1].first!).uppercased()
        }
        if let first = name.first(where: { $0.isLetter || $0.isNumber }) {
            return String(first).uppercased()
        }
        return "?"
    }

    private static func paletteColor(seed: Int) -> UIColor {
        let hue = CGFloat(abs(seed) % 360) / 360
        return UIColor(hue: hue, saturation: 0.55, brightness: 0.72, alpha: 1)
    }
}

extension UIColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 3 else { return nil }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard let value = UInt32(s, radix: 16) else { return nil }
        self.init(red: CGFloat((value >> 16) & 0xff) / 255,
                  green: CGFloat((value >> 8) & 0xff) / 255,
                  blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }

    func adjusted(brightness factor: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return UIColor(hue: h, saturation: s, brightness: min(1, b * factor), alpha: a)
    }
}
