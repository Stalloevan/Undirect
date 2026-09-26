import UIKit
import UniformTypeIdentifiers

/// "Open in Undirect" in the share sheet: takes the shared link (or text),
/// hands it to the main app through its undirect:// URL scheme, and closes.
/// If iOS refuses the hand-off, the link is copied instead so it can be
/// pasted into Undirect's address bar — never a silent dead end.
final class ShareViewController: UIViewController {

    private let card = UIView()
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 16
        label.text = "Opening in Undirect…"
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textAlignment = .center
        label.numberOfLines = 0
        spinner.startAnimating()
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.spacing = 10
        for v in [card, stack] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false }
        view.addSubview(card)
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 260),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        extractSharedItem { [weak self] payload in
            guard let self else { return }
            guard let payload, let url = Self.handoffURL(for: payload) else {
                self.finish(message: "Nothing to open here.")
                return
            }
            self.openHostApp(url) { opened in
                if opened {
                    // Leave a moment for the hand-off before the extension is torn down.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        self.extensionContext?.completeRequest(returningItems: nil)
                    }
                } else {
                    switch payload {
                    case .url(let link): UIPasteboard.general.url = link
                    case .text(let text): UIPasteboard.general.string = text
                    }
                    self.finish(message: "Couldn't open Undirect directly — the link is copied. Paste it into Undirect's address bar.")
                }
            }
        }
    }

    private func finish(message: String) {
        spinner.stopAnimating()
        label.text = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            self.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private enum Payload { case url(URL), text(String) }

    private func extractSharedItem(completion: @escaping (Payload?) -> Void) {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                var url: URL?
                if let u = item as? URL { url = u }
                else if let u = item as? NSURL { url = u as URL }
                else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let str = item as? String { url = URL(string: str) }
                let resolved = url
                DispatchQueue.main.async { completion(resolved.map(Payload.url)) }
            }
            return
        }
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                let text = (item as? String) ?? (item as? NSAttributedString)?.string
                DispatchQueue.main.async { completion(text.map(Payload.text)) }
            }
            return
        }
        completion(nil)
    }

    private static func handoffURL(for payload: Payload) -> URL? {
        var comps = URLComponents()
        comps.scheme = "undirect"
        comps.host = "open"
        switch payload {
        case .url(let url): comps.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        case .text(let text): comps.queryItems = [URLQueryItem(name: "text", value: text)]
        }
        return comps.url
    }

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
            if current.responds(to: selector), let implementation = current.method(for: selector) {
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
