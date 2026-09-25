import Foundation

/// A small rolling log of what the app has been doing — blocked redirects/
/// pop-ups, Tor state changes, content-blocker rebuilds, navigation
/// failures — kept in memory only (never written to disk on its own) so it
/// can be exported on request to help track down a problem. Nothing here is
/// sent anywhere automatically; export is an explicit action in Settings.
final class AppLog {
    static let shared = AppLog()

    private var lines: [String] = []
    private let maxLines = 3000
    private let queue = DispatchQueue(label: "com.stalloevan.undirect.applog")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        log("Undirect launched", category: "app")
    }

    func log(_ message: String, category: String = "app") {
        let line = "[\(Self.formatter.string(from: Date()))] [\(category)] \(message)"
        queue.async {
            self.lines.append(line)
            if self.lines.count > self.maxLines {
                self.lines.removeFirst(self.lines.count - self.maxLines)
            }
        }
    }

    func exportText(completion: @escaping (String) -> Void) {
        queue.async {
            var header = "Undirect log export\n"
            header += "Generated: \(Self.formatter.string(from: Date()))\n"
            header += "App version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))\n"
            header += "Theme: \(Settings.shared.appTheme.rawValue), blocklist: \(Settings.shared.blocklistLevel.rawValue)\n"
            header += "\n"
            completion(header + self.lines.joined(separator: "\n"))
        }
    }

    func clear() {
        queue.async { self.lines.removeAll() }
    }
}
