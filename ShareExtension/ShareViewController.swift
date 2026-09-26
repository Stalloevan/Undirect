import UIKit
import UniformTypeIdentifiers

/// "Open in Undirect" in the share sheet: finds the best link in whatever the
/// other app shared, hands it to the main app through its undirect:// URL
/// scheme, and closes. If iOS refuses the hand-off, the link is copied
/// instead so it can be pasted into Undirect's address bar — never a silent
/// dead end.
final class ShareViewController: UIViewController {

    private let messageLabel = PaddedMessageLabel()
    private var settled = false
    /// The sharing app goes to the background when Undirect comes forward —
    /// the most reliable sign the hand-off worked, even when iOS is slow to
    /// call the open completion during a cold launch.
    private var hostWentToBackground = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        messageLabel.isHidden = true
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 280)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(hostDidEnterBackground),
                                               name: .NSExtensionHostDidEnterBackground, object: nil)
    }

    @objc private func hostDidEnterBackground() {
        hostWentToBackground = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        extractSharedItem { [weak self] payload in
            guard let self else { return }
            guard let payload, let url = Self.handoffURL(for: payload) else {
                self.finish(message: "Nothing to open here.")
                return
            }
            // A cold launch of Undirect can take a few seconds to answer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self else { return }
                self.handleOpenResult(self.hostWentToBackground, payload: payload)
            }
            self.openHostApp(url) { [weak self] opened in
                guard let self else { return }
                if opened || self.hostWentToBackground {
                    self.handleOpenResult(true, payload: payload)
                } else {
                    // A "no" can arrive before the app switch registers;
                    // give it a moment before calling it a failure.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                        guard let self else { return }
                        self.handleOpenResult(self.hostWentToBackground, payload: payload)
                    }
                }
            }
        }
    }

    private func handleOpenResult(_ opened: Bool, payload: Payload) {
        guard !settled else { return }
        settled = true
        if opened {
            // Leave a moment for the hand-off before the extension is torn down.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.extensionContext?.completeRequest(returningItems: nil)
            }
        } else {
            switch payload {
            case .url(let link): UIPasteboard.general.url = link
            case .text(let text): UIPasteboard.general.string = text
            }
            finish(message: "Couldn't open Undirect directly — the link is copied. Paste it into Undirect's address bar.")
        }
    }

    private func finish(message: String) {
        messageLabel.text = message
        messageLabel.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            self.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private enum Payload { case url(URL), text(String) }

    // MARK: Extraction

    /// Apps share links in wildly different shapes: a proper URL item, a URL
    /// plus an image, plain text with a link somewhere inside, the link only
    /// in the item's attributed text, or a URL delivered as a string or raw
    /// data. Everything is collected and the first real web link wins; text
    /// is only used when there's no link at all.
    private func extractSharedItem(completion: @escaping (Payload?) -> Void) {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let collector = ShareCollector()
        let group = DispatchGroup()

        for item in items {
            collector.add(text: item.attributedContentText?.string)
            collector.add(text: item.attributedTitle?.string)
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier) { value, _ in
                        if let url = Self.coerceURL(value), Self.isWeb(url) { collector.add(url: url) }
                        if let s = value as? String { collector.add(text: s) }
                        group.leave()
                    }
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { value, _ in
                        collector.add(text: (value as? String) ?? (value as? NSAttributedString)?.string
                                      ?? (value as? Data).flatMap { String(data: $0, encoding: .utf8) })
                        group.leave()
                    }
                }
            }
        }

        let deliver = {
            // Runs once: whichever comes first of "all loaded" or the timeout
            // (some providers never call back).
            guard collector.claimDelivery() else { return }
            let (urls, texts) = collector.snapshot()
            if let url = urls.first { completion(.url(url)); return }
            for text in texts {
                if let url = Self.firstWebLink(in: text) { completion(.url(url)); return }
            }
            completion(texts.first.map(Payload.text))
        }
        group.notify(queue: .main, execute: deliver)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: deliver)
    }

    private static func coerceURL(_ value: NSSecureCoding?) -> URL? {
        if let u = value as? URL { return u }
        if let u = value as? NSURL { return u as URL }
        if let s = value as? String { return URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let data = value as? Data {
            if let u = URL(dataRepresentation: data, relativeTo: nil), isWeb(u) { return u }
            if let s = String(data: data, encoding: .utf8) { return URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return nil
    }

    private static func isWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    private static func firstWebLink(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return detector?.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap(\.url).first(where: isWeb)
    }

    /// The link rides inside our own URL, so it's encoded with a strict set:
    /// a shared link's own `&`, `=`, `#`, `+` or `%` must survive untouched.
    private static func handoffURL(for payload: Payload) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let pair: (key: String, value: String)
        switch payload {
        case .url(let url): pair = ("url", url.absoluteString)
        case .text(let text): pair = ("text", String(text.prefix(4000)))
        }
        let key = pair.key
        let value = pair.value
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "undirect://open?\(key)=\(encoded)")
    }

    // MARK: Hand-off

    /// Extensions can't call UIApplication.open directly (it's marked
    /// extension-unavailable), but the extension process's application object
    /// is reachable up the responder chain, so the same method is invoked
    /// through the Objective-C runtime, with a real completion callback so a
    /// refusal is detected rather than ignored.
    private func openHostApp(_ url: URL, completion: @escaping (Bool) -> Void) {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        typealias OpenFunction = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
        var responder: UIResponder? = self
        while let current = responder {
            // Only the actual application object: some of the share sheet's
            // own internal responders also answer to this selector but just
            // swallow the request.
            if current is UIApplication, current.responds(to: selector),
               let implementation = current.method(for: selector) {
                let open = unsafeBitCast(implementation, to: OpenFunction.self)
                let callback: @convention(block) (Bool) -> Void = { ok in
                    DispatchQueue.main.async { completion(ok) }
                }
                open(current, selector, url as NSURL, NSDictionary(), callback as AnyObject)
                return
            }
            responder = current.next
        }
        completion(false)
    }
}

/// Thread-safe accumulator for item-provider callbacks.
private final class ShareCollector {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var texts: [String] = []
    private var delivered = false

    func add(url: URL) {
        lock.lock(); urls.append(url); lock.unlock()
    }

    func add(text: String?) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lock.lock(); texts.append(text); lock.unlock()
    }

    func claimDelivery() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if delivered { return false }
        delivered = true
        return true
    }

    func snapshot() -> ([URL], [String]) {
        lock.lock(); defer { lock.unlock() }
        return (urls, texts)
    }
}

private final class PaddedMessageLabel: UILabel {
    override init(frame: CGRect) {
        super.init(frame: frame)
        font = .systemFont(ofSize: 15, weight: .medium)
        textAlignment = .center
        numberOfLines = 0
        textColor = .label
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 14
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 16, dy: 14)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + 32, height: s.height + 28)
    }
}
