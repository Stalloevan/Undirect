import UIKit
import WebKit
import Photos
import QuickLook
import UniformTypeIdentifiers

// MARK: - Model

/// What happens to a finished download.
///
/// iOS never lets one app silently push a file into a *specific* other app.
/// The two ways that come closest are both here: "Save to folder" (pick a
/// folder once — including another app's own folder in Files, like VLC's or
/// Documents' — and matching files land there automatically), and "Open in
/// app", which brings up the system share sheet already holding the file so
/// sending it to an app is a single tap.
enum DownloadAction: String, Codable, CaseIterable {
    case ask, keep, folder, openIn, chooseLocation, photos, preview

    var title: String {
        switch self {
        case .ask: return "Ask every time"
        case .keep: return "Undirect Downloads folder"
        case .folder: return "A folder I choose…"
        case .openIn: return "Open in app (share sheet)"
        case .chooseLocation: return "Pick a location each time"
        case .photos: return "Photos library"
        case .preview: return "Preview in Undirect"
        }
    }

    var shortTitle: String {
        switch self {
        case .ask: return "Ask"
        case .keep: return "Undirect Downloads"
        case .folder: return "Folder"
        case .openIn: return "Open in app"
        case .chooseLocation: return "Pick location"
        case .photos: return "Photos"
        case .preview: return "Preview"
        }
    }
}

struct DownloadRule: Codable, Equatable {
    var id = UUID()
    var name: String
    /// MIME patterns: "application/pdf", "image/*" or "*/*".
    var patterns: [String]
    var action: DownloadAction
    var folderBookmark: Data?
    var folderName: String?

    var summary: String {
        if action == .folder, let folderName { return "→ \(folderName)" }
        return action.shortTitle
    }

    /// 2 = exact type, 1 = "type/*", 0 = "*/*", nil = no match.
    func score(for mime: String) -> Int? {
        let mime = mime.lowercased()
        var best: Int?
        for raw in patterns {
            let p = raw.trimmingCharacters(in: .whitespaces).lowercased()
            let s: Int?
            if p == mime { s = 2 }
            else if p == "*/*" || p == "*" { s = 0 }
            else if p.hasSuffix("/*"), mime.hasPrefix(String(p.dropLast())) { s = 1 }
            else { s = nil }
            if let s, s > (best ?? -1) { best = s }
        }
        return best
    }
}

struct DownloadPreset {
    let name: String
    let patterns: [String]

    static let all: [DownloadPreset] = [
        DownloadPreset(name: "Images", patterns: ["image/*"]),
        DownloadPreset(name: "Video", patterns: ["video/*"]),
        DownloadPreset(name: "Audio", patterns: ["audio/*"]),
        DownloadPreset(name: "PDF", patterns: ["application/pdf"]),
        DownloadPreset(name: "Archives", patterns: [
            "application/zip", "application/x-zip-compressed", "application/x-7z-compressed",
            "application/vnd.rar", "application/x-rar-compressed", "application/gzip",
            "application/x-gzip", "application/x-tar", "application/x-bzip2", "application/x-xz"
        ]),
        DownloadPreset(name: "Documents", patterns: [
            "application/msword", "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.ms-excel", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "application/vnd.ms-powerpoint", "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "application/rtf", "application/vnd.oasis.opendocument.text", "text/csv"
        ]),
        DownloadPreset(name: "Text & code", patterns: ["text/*", "application/json", "application/xml"]),
        DownloadPreset(name: "eBooks", patterns: ["application/epub+zip"]),
        DownloadPreset(name: "Torrents", patterns: ["application/x-bittorrent"]),
        DownloadPreset(name: "iOS apps (IPA)", patterns: ["application/x-ios-app", "application/octet-stream+ipa"])
    ]
}

final class DownloadRuleStore {
    static let shared = DownloadRuleStore()
    static let didChange = Notification.Name("UndirectDownloadRulesDidChange")

    private let key = "downloads.rules.v1"
    private let defaultKey = "downloads.default.v1"

    private(set) var rules: [DownloadRule]
    private(set) var fallback: DownloadRule

    private init() {
        let d = UserDefaults.standard
        rules = (d.data(forKey: key).flatMap { try? JSONDecoder().decode([DownloadRule].self, from: $0) }) ?? []
        fallback = (d.data(forKey: defaultKey).flatMap { try? JSONDecoder().decode(DownloadRule.self, from: $0) })
            ?? DownloadRule(name: "Everything else", patterns: ["*/*"], action: .ask)
    }

    func rule(for mime: String, filename: String) -> DownloadRule {
        var best: (DownloadRule, Int)?
        for rule in rules {
            if let s = rule.score(for: mime), s > (best?.1 ?? -1) { best = (rule, s) }
        }
        // IPAs are served as octet-stream; recognise them by extension.
        if filename.lowercased().hasSuffix(".ipa"),
           let ipa = rules.first(where: { $0.patterns.contains("application/x-ios-app") }) {
            return ipa
        }
        return best?.0 ?? fallback
    }

    func upsert(_ rule: DownloadRule) {
        if rule.id == fallback.id {
            fallback = rule
        } else if let i = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[i] = rule
        } else {
            rules.append(rule)
        }
        save()
    }

    func remove(id: UUID) {
        rules.removeAll { $0.id == id }
        save()
    }

    func move(from: Int, to: Int) {
        let r = rules.remove(at: from)
        rules.insert(r, at: to)
        save()
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(rules), forKey: key)
        d.set(try? JSONEncoder().encode(fallback), forKey: defaultKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

// MARK: - Manager

final class DownloadManager: NSObject {
    static let shared = DownloadManager()
    /// object: String message for the browser to show as a toast.
    static let toastNotification = Notification.Name("UndirectDownloadToast")

    private struct Active {
        var fileURL: URL?
        var filename: String
        var mime: String
        let isTor: Bool
    }
    private var active: [ObjectIdentifier: Active] = [:]
    /// Held while a Quick Look preview is on screen.
    private var previewSource: PreviewSource?
    /// Held while a document picker is on screen.
    private var pickerDelegate: PickerDelegate?

    static var downloadsFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var stagingFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("UndirectDownloads", isDirectory: true)
    }

    private override init() {
        super.init()
        // Anything left in staging from a previous run was never handed off.
        try? FileManager.default.removeItem(at: Self.stagingFolder)
    }

    // MARK: Decisions (called from Tab)

    /// Whether a main-frame response should be saved rather than shown.
    static func shouldDownload(_ response: WKNavigationResponse) -> Bool {
        guard response.isForMainFrame else { return false }
        if !response.canShowMIMEType { return true }
        if let http = response.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
           disposition.hasPrefix("attachment") {
            return true
        }
        return false
    }

    func track(_ download: WKDownload, isTor: Bool) {
        download.delegate = self
        let name = download.originalRequest?.url?.lastPathComponent ?? "download"
        active[ObjectIdentifier(download)] = Active(fileURL: nil, filename: name, mime: "application/octet-stream", isTor: isTor)
    }

    // MARK: Routing

    private func route(fileURL: URL, filename: String, mime: String) {
        let rule = DownloadRuleStore.shared.rule(for: mime, filename: filename)
        AppLog.shared.log("Downloaded \(filename) (\(mime)) → \(rule.action.rawValue)", category: "download")
        perform(rule.action, rule: rule, fileURL: fileURL, filename: filename, mime: mime)
    }

    private func perform(_ action: DownloadAction, rule: DownloadRule?, fileURL: URL, filename: String, mime: String) {
        switch action {
        case .ask:
            presentChoices(fileURL: fileURL, filename: filename, mime: mime)
        case .keep:
            if let saved = moveToDownloads(fileURL, filename: filename) {
                toast("Saved \(saved.lastPathComponent) to Undirect Downloads")
            }
        case .folder:
            guard let bookmark = rule?.folderBookmark else {
                toast("No folder set for this rule — choose what to do")
                presentChoices(fileURL: fileURL, filename: filename, mime: mime)
                return
            }
            saveToBookmarkedFolder(bookmark, rule: rule, fileURL: fileURL, filename: filename, mime: mime)
        case .openIn:
            presentShareSheet(fileURL)
        case .chooseLocation:
            presentExportPicker(fileURL)
        case .photos:
            saveToPhotos(fileURL: fileURL, filename: filename, mime: mime)
        case .preview:
            if let saved = moveToDownloads(fileURL, filename: filename) { presentPreview(saved) }
        }
    }

    private func presentChoices(fileURL: URL, filename: String, mime: String) {
        guard let presenter = Self.topViewController() else {
            _ = moveToDownloads(fileURL, filename: filename)
            return
        }
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
        let sizeText = size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
        let sheet = UIAlertController(title: filename,
                                      message: [sizeText, mime].filter { !$0.isEmpty }.joined(separator: " · ")
                                        + "\nSet automatic rules in Settings › Downloads.",
                                      preferredStyle: .actionSheet)
        let add: (DownloadAction, String) -> Void = { [weak self] action, title in
            sheet.addAction(UIAlertAction(title: title, style: .default) { _ in
                self?.perform(action, rule: nil, fileURL: fileURL, filename: filename, mime: mime)
            })
        }
        add(.openIn, "Open in App…")
        add(.chooseLocation, "Save to Files…")
        if Self.isPhotoCompatible(mime) { add(.photos, "Save to Photos") }
        add(.keep, "Keep in Undirect Downloads")
        add(.preview, "Preview")
        sheet.addAction(UIAlertAction(title: "Discard", style: .destructive) { _ in
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        })
        Self.anchor(sheet, in: presenter)
        presenter.present(sheet, animated: true)
    }

    private func moveToDownloads(_ fileURL: URL, filename: String) -> URL? {
        let dest = Self.uniqueURL(in: Self.downloadsFolder, name: filename)
        do {
            try FileManager.default.moveItem(at: fileURL, to: dest)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            return dest
        } catch {
            toast("Couldn't save \(filename)")
            AppLog.shared.log("Save to Downloads failed: \(error.localizedDescription)", category: "download")
            return nil
        }
    }

    private func saveToBookmarkedFolder(_ bookmark: Data, rule: DownloadRule?, fileURL: URL, filename: String, mime: String) {
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            toast("That folder is no longer available — choose what to do")
            presentChoices(fileURL: fileURL, filename: filename, mime: mime)
            return
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        if stale, var rule, let fresh = try? folder.bookmarkData() {
            rule.folderBookmark = fresh
            DownloadRuleStore.shared.upsert(rule)
        }
        let dest = Self.uniqueURL(in: folder, name: filename)
        var coordinationError: NSError?
        var copyError: Error?
        // Coordinated write so file-provider folders (iCloud Drive, other
        // apps' storage) pick the new file up correctly.
        NSFileCoordinator().coordinate(writingItemAt: dest, options: .forReplacing, error: &coordinationError) { url in
            do { try FileManager.default.copyItem(at: fileURL, to: url) } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError {
            AppLog.shared.log("Save to folder failed: \(error.localizedDescription)", category: "download")
            toast("Couldn't save to \(folder.lastPathComponent) — choose what to do")
            presentChoices(fileURL: fileURL, filename: filename, mime: mime)
            return
        }
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        toast("Saved \(dest.lastPathComponent) to \(rule?.folderName ?? folder.lastPathComponent)")
    }

    private func presentShareSheet(_ fileURL: URL) {
        guard let presenter = Self.topViewController() else { return }
        let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        activity.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
        Self.anchor(activity, in: presenter)
        presenter.present(activity, animated: true)
    }

    private func presentExportPicker(_ fileURL: URL) {
        guard let presenter = Self.topViewController() else { return }
        let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        let delegate = PickerDelegate { [weak self] picked in
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            if let name = picked?.first?.lastPathComponent { self?.toast("Saved \(name)") }
            self?.pickerDelegate = nil
        }
        pickerDelegate = delegate
        picker.delegate = delegate
        presenter.present(picker, animated: true)
    }

    private static func isPhotoCompatible(_ mime: String) -> Bool {
        mime.hasPrefix("image/") || mime.hasPrefix("video/")
    }

    private func saveToPhotos(fileURL: URL, filename: String, mime: String) {
        guard Self.isPhotoCompatible(mime) else {
            // Not something Photos can hold — don't lose it.
            if let saved = moveToDownloads(fileURL, filename: filename) {
                toast("Not a photo or video — saved \(saved.lastPathComponent) to Undirect Downloads")
            }
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    if let saved = self?.moveToDownloads(fileURL, filename: filename) {
                        self?.toast("No Photos access — saved \(saved.lastPathComponent) to Undirect Downloads")
                    }
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: mime.hasPrefix("video/") ? .video : .photo, fileURL: fileURL, options: nil)
            }) { ok, error in
                DispatchQueue.main.async {
                    if ok {
                        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
                        self?.toast("Saved to Photos")
                    } else {
                        AppLog.shared.log("Save to Photos failed: \(error?.localizedDescription ?? "?")", category: "download")
                        if let saved = self?.moveToDownloads(fileURL, filename: filename) {
                            self?.toast("Photos couldn't take it — saved \(saved.lastPathComponent) to Undirect Downloads")
                        }
                    }
                }
            }
        }
    }

    private func presentPreview(_ url: URL) {
        guard let presenter = Self.topViewController() else { return }
        let source = PreviewSource(url: url)
        previewSource = source
        let ql = QLPreviewController()
        ql.dataSource = source
        presenter.present(ql, animated: true)
    }

    private func toast(_ message: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.toastNotification, object: message)
        }
    }

    // MARK: Helpers

    static func uniqueURL(in folder: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = folder.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }

    static func sanitize(_ filename: String) -> String {
        let cleaned = filename
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\0"))
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "download" : String(cleaned.prefix(180))
    }

    static func resolveMIME(_ reported: String?, filename: String) -> String {
        let generic: Set<String> = ["application/octet-stream", "binary/octet-stream", "application/download",
                                    "application/force-download", "application/x-download"]
        if let reported = reported?.lowercased(), !reported.isEmpty, !generic.contains(reported) { return reported }
        let ext = (filename as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime.lowercased()
        }
        return reported?.lowercased() ?? "application/octet-stream"
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }

    static func anchor(_ vc: UIViewController, in presenter: UIViewController) {
        if let pop = vc.popoverPresentationController {
            pop.sourceView = presenter.view
            pop.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 80, width: 0, height: 0)
        }
    }
}

extension DownloadManager: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let filename = Self.sanitize(suggestedFilename)
        let mime = Self.resolveMIME(response.mimeType, filename: filename)
        let folder = Self.stagingFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            completionHandler(nil)
            return
        }
        let dest = folder.appendingPathComponent(filename)
        let id = ObjectIdentifier(download)
        var info = active[id] ?? Active(fileURL: nil, filename: filename, mime: mime, isTor: false)
        info.fileURL = dest
        info.filename = filename
        info.mime = mime
        active[id] = info
        toast("Downloading \(filename)…")
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let info = active.removeValue(forKey: ObjectIdentifier(download)), let url = info.fileURL else { return }
        route(fileURL: url, filename: info.filename, mime: info.mime)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let info = active.removeValue(forKey: ObjectIdentifier(download))
        if let folder = info?.fileURL?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: folder) }
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        AppLog.shared.log("Download failed (\(info?.filename ?? "?")): \(error.localizedDescription)", category: "download")
        toast("Download failed: \(info?.filename ?? "file")")
    }
}

private final class PreviewSource: NSObject, QLPreviewControllerDataSource {
    let url: URL
    init(url: URL) { self.url = url }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
}

private final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
    let done: ([URL]?) -> Void
    init(done: @escaping ([URL]?) -> Void) { self.done = done }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done(urls) }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done(nil) }
}

// MARK: - Settings UI

final class DownloadSettingsViewController: UITableViewController {

    private var folderPickRule: DownloadRule?
    private var folderPickerDelegate: PickerDelegate?

    init() { super.init(style: Theme.tableViewStyle) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Downloads"
        tableView.backgroundColor = Theme.background
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addRule)),
            editButtonItem
        ]
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: DownloadRuleStore.didChange, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        tableView.reloadData()
    }

    @objc private func reload() { tableView.reloadData() }

    private var rules: [DownloadRule] { DownloadRuleStore.shared.rules }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        ["Rules by file type", "Everything else", nil][section]
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0:
            return "The most specific match wins (e.g. “application/pdf” beats “*/*”). Tap a rule to change where it goes, swipe to delete."
        case 1:
            return "iOS doesn't let apps silently send a file into a specific other app. “A folder I choose…” is the closest: pick another app's folder in Files (for example On My iPhone › VLC) and matching files go straight there. “Open in app” shows the share sheet with the file ready, so sending it is one tap."
        default:
            return "Undirect Downloads is visible in the Files app under On My iPhone › Undirect."
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        [max(rules.count, 1), 1, 1][section]
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Theme.surface
        cell.textLabel?.textColor = Theme.text
        cell.detailTextLabel?.textColor = Theme.secondaryText
        cell.detailTextLabel?.numberOfLines = 2
        switch indexPath.section {
        case 0:
            guard !rules.isEmpty else {
                cell.textLabel?.text = "No rules yet — tap + to add one"
                cell.textLabel?.textColor = Theme.secondaryText
                cell.selectionStyle = .none
                return cell
            }
            let rule = rules[indexPath.row]
            cell.textLabel?.text = "\(rule.name)  \(rule.summary)"
            cell.detailTextLabel?.text = rule.patterns.joined(separator: ", ")
            cell.accessoryType = .disclosureIndicator
        case 1:
            let rule = DownloadRuleStore.shared.fallback
            cell.textLabel?.text = "All other files  \(rule.summary)"
            cell.detailTextLabel?.text = "*/*"
            cell.accessoryType = .disclosureIndicator
        default:
            cell.textLabel?.text = "Open Undirect Downloads in Files"
            cell.textLabel?.textColor = Theme.accent
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch indexPath.section {
        case 0:
            guard !rules.isEmpty else { addRule(); return }
            chooseAction(for: rules[indexPath.row], from: tableView.cellForRow(at: indexPath))
        case 1:
            chooseAction(for: DownloadRuleStore.shared.fallback, from: tableView.cellForRow(at: indexPath))
        default:
            openDownloadsInFiles()
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        indexPath.section == 0 && !rules.isEmpty
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        indexPath.section == 0 && rules.count > 1
    }

    override func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt source: IndexPath,
                            toProposedIndexPath proposed: IndexPath) -> IndexPath {
        proposed.section == 0 ? proposed : IndexPath(row: rules.count - 1, section: 0)
    }

    override func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        DownloadRuleStore.shared.move(from: source.row, to: destination.row)
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, rules.indices.contains(indexPath.row) else { return }
        DownloadRuleStore.shared.remove(id: rules[indexPath.row].id)
    }

    // MARK: Adding / editing

    @objc private func addRule() {
        let sheet = UIAlertController(title: "Add a rule for…", message: nil, preferredStyle: .actionSheet)
        for preset in DownloadPreset.all {
            sheet.addAction(UIAlertAction(title: preset.name, style: .default) { [weak self] _ in
                let rule = DownloadRule(name: preset.name, patterns: preset.patterns, action: .ask)
                self?.chooseAction(for: rule, from: nil)
            })
        }
        sheet.addAction(UIAlertAction(title: "Custom MIME type…", style: .default) { [weak self] _ in self?.promptCustom() })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        DownloadManager.anchor(sheet, in: self)
        present(sheet, animated: true)
    }

    private func promptCustom() {
        let alert = UIAlertController(title: "Custom file types",
                                      message: "One or more MIME types, comma-separated. Wildcards like image/* work.",
                                      preferredStyle: .alert)
        alert.addTextField { f in
            f.placeholder = "application/x-bittorrent, video/*"
            f.autocapitalizationType = .none
            f.autocorrectionType = .no
            f.keyboardType = .URL
        }
        alert.addTextField { f in f.placeholder = "Name (optional)" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Next", style: .default) { [weak self] _ in
            let raw = alert.textFields?[0].text ?? ""
            let patterns = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { $0.contains("/") }
            guard !patterns.isEmpty else { return }
            let name = alert.textFields?[1].text?.trimmingCharacters(in: .whitespaces)
            self?.chooseAction(for: DownloadRule(name: (name?.isEmpty == false ? name! : patterns[0]), patterns: patterns, action: .ask), from: nil)
        })
        present(alert, animated: true)
    }

    private func chooseAction(for rule: DownloadRule, from cell: UITableViewCell?) {
        let sheet = UIAlertController(title: "\(rule.name) go to…", message: nil, preferredStyle: .actionSheet)
        for action in DownloadAction.allCases {
            if action == .photos, !rule.patterns.contains(where: { $0.hasPrefix("image/") || $0.hasPrefix("video/") || $0 == "*/*" }) {
                continue
            }
            let checked = action == rule.action ? " ✓" : ""
            sheet.addAction(UIAlertAction(title: action.title + checked, style: .default) { [weak self] _ in
                var updated = rule
                updated.action = action
                if action == .folder {
                    self?.pickFolder(for: updated)
                } else {
                    updated.folderBookmark = nil
                    updated.folderName = nil
                    DownloadRuleStore.shared.upsert(updated)
                }
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let pop = sheet.popoverPresentationController, let cell {
            pop.sourceView = cell
            pop.sourceRect = cell.bounds
        } else {
            DownloadManager.anchor(sheet, in: self)
        }
        present(sheet, animated: true)
    }

    private func pickFolder(for rule: DownloadRule) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        let delegate = PickerDelegate { [weak self] urls in
            defer { self?.folderPickerDelegate = nil }
            guard let folder = urls?.first else { return }
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            guard let bookmark = try? folder.bookmarkData() else {
                self?.alert("Couldn't remember that folder. Try another one.")
                return
            }
            var updated = rule
            updated.folderBookmark = bookmark
            updated.folderName = folder.lastPathComponent
            DownloadRuleStore.shared.upsert(updated)
        }
        folderPickerDelegate = delegate
        picker.delegate = delegate
        present(picker, animated: true)
    }

    private func openDownloadsInFiles() {
        let path = DownloadManager.downloadsFolder.path
        if let url = URL(string: "shareddocuments://" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)) {
            UIApplication.shared.open(url) { [weak self] ok in
                if !ok { self?.alert("Open the Files app and go to On My iPhone › Undirect › Downloads.") }
            }
        }
    }

    private func alert(_ text: String) {
        let a = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        present(a, animated: true)
    }
}
