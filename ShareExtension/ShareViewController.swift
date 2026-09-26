import UIKit
import UniformTypeIdentifiers

/// "Open in Undirect" in the share sheet: takes the shared link (or text),
/// hands it to the main app through its undirect:// URL scheme, and closes.
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        extractSharedItem { [weak self] payload in
            guard let self else { return }
            if let payload, let url = Self.handoffURL(for: payload) {
                self.openHostApp(url)
            }
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

    /// Extensions can't call UIApplication.shared.open directly, but the
    /// extension process's UIApplication is reachable up the responder chain.
    private func openHostApp(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let app = current as? UIApplication {
                app.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = current.next
        }
    }
}
