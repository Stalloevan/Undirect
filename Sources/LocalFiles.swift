import Foundation
import UniformTypeIdentifiers

/// HTML files opened from the Files app, the share sheet ("Open in
/// Undirect"), a download, or ⋯ › Open File. Each is copied into its own
/// folder inside Undirect's storage and loaded from there, so:
/// - it keeps working after the original is moved or the app restarts
///   (restored tabs point at the copy), and
/// - a page can only read files in its own folder, never anything else.
enum LocalFiles {

    /// object: URL of a file to open in a new tab (e.g. a downloaded page).
    static let openNotification = Notification.Name("UndirectOpenLocalFile")

    static let openableTypes: [UTType] = {
        var types: [UTType] = [.html, .webArchive]
        if let xhtml = UTType("public.xhtml") { types.append(xhtml) }
        return types
    }()
    static let extensions: Set<String> = ["html", "htm", "xhtml", "xht", "webarchive"]

    static var root: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("OpenedFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Whether `url` is one of our copies (the only file:// URLs tabs may load).
    static func contains(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return canonicalPath(url).hasPrefix(canonicalPath(root) + "/")
    }

    static func isOpenable(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Copies a file (security-scoped if it came from outside the app) into
    /// its own folder and returns the copy.
    static func importFile(_ source: URL, move: Bool = false) -> URL? {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let name = source.lastPathComponent.isEmpty ? "page.html" : source.lastPathComponent
        let dest = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
                do {
                    if move { try FileManager.default.moveItem(at: readable, to: dest) }
                    else { try FileManager.default.copyItem(at: readable, to: dest) }
                } catch { copyError = error }
            }
            if let error = coordinationError ?? copyError { throw error }
            return dest
        } catch {
            AppLog.shared.log("Couldn't open file \(name): \(error.localizedDescription)", category: "app")
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }

    /// Deletes copies no open tab refers to any more.
    static func prune(keeping urls: [URL]) {
        let keep = Set(urls.filter(contains).map { canonicalPath($0.deletingLastPathComponent()) })
        DispatchQueue.global(qos: .utility).async {
            let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for folder in folders where !keep.contains(canonicalPath(folder)) {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }
}
