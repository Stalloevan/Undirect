import UIKit
import WebKit

enum TrustLevel {
    case good, caution, warning

    var title: String {
        switch self {
        case .good: return "Looks OK"
        case .caution: return "Use caution"
        case .warning: return "Higher risk"
        }
    }

    var color: UIColor {
        switch self {
        case .good: return .systemGreen
        case .caution: return .systemOrange
        case .warning: return .systemRed
        }
    }
}

struct TrustAssessment {
    let level: TrustLevel
    let score: Int
    let reasons: [String]
}

/// What the background preview load actually found on the page, so the score
/// reflects the real page instead of just guessing from the URL alone.
struct PageSignals {
    let adResourceCount: Int
    let thirdPartyCookieCount: Int
}

/// A local, offline heuristic — not a real security verdict. The URL-only
/// part never makes a network request; once a page preview signal is
/// available (see LinkPagePreviewLoader) it's folded in too. No lookup is
/// ever sent to a third party — that would itself be tracking every link you
/// hover, which is exactly what this browser exists to avoid.
enum TrustScorer {
    private static let riskyTLDs: Set<String> = [
        "tk", "ml", "ga", "cf", "gq", "xyz", "top", "click", "work", "link", "zip", "review"
    ]

    static func assess(url: URL, pageSignals: PageSignals? = nil) -> TrustAssessment {
        var score = 70
        var reasons: [String] = []
        let host = DomainUtil.normalize(url.host ?? "")

        if url.scheme?.lowercased() == "https" {
            score += 10
        } else {
            score -= 25
            reasons.append("Not using HTTPS")
        }

        if host.range(of: #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$"#, options: .regularExpression) != nil {
            score -= 20
            reasons.append("Raw IP address instead of a domain name")
        }

        if host.contains("xn--") {
            score -= 20
            reasons.append("Uses punycode — check it's not a lookalike domain")
        }

        if host.split(separator: ".").count > 4 {
            score -= 10
            reasons.append("Unusually many subdomains")
        }

        if let tld = host.split(separator: ".").last.map(String.init), riskyTLDs.contains(tld) {
            score -= 10
            reasons.append(".\(tld) is a commonly abused domain ending")
        }

        if ContentBlocker.shared.isBlocked(host: host) {
            score -= 45
            reasons.append("On the ad/tracker blocklist")
        }

        for category in SiteReputationIndex.categories(for: host) {
            score -= category.penalty
            reasons.append("Listed as \(category.label)")
        }

        if WhitelistStore.shared.isWhitelisted(host: host) {
            score += 15
            reasons.append("You've trusted this site")
        }

        if let signals = pageSignals {
            if signals.adResourceCount > 0 {
                score -= min(30, signals.adResourceCount * 5)
                reasons.append("\(signals.adResourceCount) ad/tracker resource\(signals.adResourceCount == 1 ? "" : "s") found on the page")
            }
            if signals.thirdPartyCookieCount > 3 {
                score -= min(20, signals.thirdPartyCookieCount * 2)
                reasons.append("\(signals.thirdPartyCookieCount) third-party cookies set")
            } else if signals.adResourceCount == 0 && signals.thirdPartyCookieCount == 0 {
                score += 5
                reasons.append("No ad/tracker resources or third-party cookies found")
            }
        }

        score = max(0, min(100, score))
        let level: TrustLevel = score >= 70 ? .good : (score >= 40 ? .caution : .warning)
        if reasons.isEmpty { reasons = ["No notable risk signals found"] }
        return TrustAssessment(level: level, score: score, reasons: reasons)
    }
}

/// Briefly loads a link's destination in an offscreen web view — the same
/// way the real tab would (Tor tab links load over Tor too, with the usual
/// content-blocking rules applied) — to get a real snapshot of the page and
/// count the ad/tracker resources and third-party cookies it actually has,
/// then tears the web view down. Nothing here is more revealing to the
/// destination site than actually visiting it would be.
final class LinkPagePreviewLoader: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var completion: ((UIImage?, PageSignals?) -> Void)?
    private var timeoutWork: DispatchWorkItem?
    private var settled = false

    func load(url: URL, isTor: Bool, completion: @escaping (UIImage?, PageSignals?) -> Void) {
        self.completion = completion
        let config = WebEngine.makeConfiguration(tor: isTor)
        ContentBlocker.shared.apply(to: config.userContentController, paused: ContentBlocker.shared.paused.contains(host: url.host))

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: config)
        wv.navigationDelegate = self
        webView = wv
        wv.load(URLRequest(url: url))

        let work = DispatchWorkItem { [weak self] in self?.finish() }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !settled else { return }
        // Give the page a brief moment to paint and for late ad/tracker
        // resources to register before inspecting and snapshotting it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.finish() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }

    private func finish() {
        guard !settled, let wv = webView else { return }
        settled = true
        timeoutWork?.cancel()

        countAdResources(in: wv) { [weak self] adCount in
            guard let self else { return }
            wv.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let host = wv.url?.host.map(DomainUtil.baseDomain)
                let thirdParty = cookies.filter { host == nil || DomainUtil.baseDomain($0.domain) != host }.count
                let signals = PageSignals(adResourceCount: adCount, thirdPartyCookieCount: thirdParty)
                let snapConfig = WKSnapshotConfiguration()
                wv.takeSnapshot(with: snapConfig) { image, _ in
                    self.completion?(image, signals)
                    self.completion = nil
                    self.teardown()
                }
            }
        }
    }

    private func countAdResources(in webView: WKWebView, completion: @escaping (Int) -> Void) {
        let js = """
        (function () {
          var els = document.querySelectorAll('script[src], img[src], iframe[src]');
          var hosts = [];
          for (var i = 0; i < els.length; i++) {
            try { hosts.push(new URL(els[i].src, location.href).hostname); } catch (e) {}
          }
          return hosts;
        })();
        """
        webView.evaluateJavaScript(js) { value, _ in
            let hosts = (value as? [String]) ?? []
            let blockedCount = Set(hosts.filter { ContentBlocker.shared.isBlocked(host: $0) }).count
            completion(blockedCount)
        }
    }

    private func teardown() {
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
    }
}

/// The custom preview shown above the long-press menu on a link, in place of
/// WebKit's default plain thumbnail: a real snapshot of the destination page
/// plus a trust score that updates once the page has actually been inspected.
final class LinkPreviewViewController: UIViewController {
    private let url: URL
    private let isTor: Bool
    private let loader = LinkPagePreviewLoader()

    private let pageImageView = UIImageView()
    private let pageSpinner = UIActivityIndicatorView(style: .medium)
    private let badge = PaddedLabel()
    private let reasonsLabel = UILabel()

    private static let pageAreaHeight: CGFloat = 170

    init(url: URL, isTor: Bool) {
        self.url = url
        self.isTor = isTor
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.surface
        preferredContentSize = CGSize(width: 300, height: 0)

        let assessment = TrustScorer.assess(url: url)
        let host = url.host.map(DomainUtil.normalize) ?? url.absoluteString

        pageImageView.contentMode = .scaleAspectFill
        pageImageView.clipsToBounds = true
        pageImageView.backgroundColor = Theme.field
        pageImageView.layer.cornerRadius = Theme.smallCornerRadius
        pageSpinner.color = Theme.secondaryText
        pageSpinner.startAnimating()

        let iconView = UIImageView(image: FaviconStore.shared.cached(host: url.host) ?? FaviconStore.monogram(for: url.host, tor: isTor))
        iconView.layer.cornerRadius = Theme.smallCornerRadius
        iconView.clipsToBounds = true
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 26).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let hostLabel = UILabel()
        hostLabel.text = host
        hostLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        hostLabel.textColor = Theme.text
        hostLabel.lineBreakMode = .byTruncatingMiddle

        let headerRow = UIStackView(arrangedSubviews: [iconView, hostLabel])
        headerRow.spacing = 8
        headerRow.alignment = .center

        configureBadge(with: assessment)
        let badgeRow = UIStackView(arrangedSubviews: [badge, UIView()])

        reasonsLabel.text = assessment.reasons.map { "•  \($0)" }.joined(separator: "\n")
        reasonsLabel.font = .systemFont(ofSize: 12)
        reasonsLabel.textColor = Theme.secondaryText
        reasonsLabel.numberOfLines = 0

        let disclaimer = UILabel()
        disclaimer.text = "Local heuristic, not a security guarantee."
        disclaimer.font = .italicSystemFont(ofSize: 10)
        disclaimer.textColor = Theme.secondaryText
        disclaimer.numberOfLines = 0

        for v in [pageImageView, pageSpinner] { v.translatesAutoresizingMaskIntoConstraints = false }
        pageImageView.heightAnchor.constraint(equalToConstant: Self.pageAreaHeight).isActive = true
        pageImageView.addSubview(pageSpinner)
        NSLayoutConstraint.activate([
            pageSpinner.centerXAnchor.constraint(equalTo: pageImageView.centerXAnchor),
            pageSpinner.centerYAnchor.constraint(equalTo: pageImageView.centerYAnchor)
        ])

        let stack = UIStackView(arrangedSubviews: [pageImageView, headerRow, badgeRow, reasonsLabel, disclaimer])
        stack.axis = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(12, after: pageImageView)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14)
        ])

        // The page-preview area's height is already reserved above, so the
        // preview bubble's final size is correct from the start — only the
        // *content* inside it changes once the load finishes, not the size.
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let height = stack.systemLayoutSizeFitting(CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)).height + 28 + 34
        preferredContentSize = CGSize(width: 300, height: height)

        if !isTor {
            FaviconStore.shared.fetch(host: url.host ?? "", hint: nil) { [weak iconView] image in
                guard let image else { return }
                iconView?.image = image
            }
        }

        loader.load(url: url, isTor: isTor) { [weak self] image, signals in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pageSpinner.stopAnimating()
                if let image {
                    UIView.transition(with: self.pageImageView, duration: 0.2, options: .transitionCrossDissolve) {
                        self.pageImageView.image = image
                    }
                } else {
                    self.pageSpinner.stopAnimating()
                    let placeholder = UIImageView(image: Theme.icon("photo"))
                    placeholder.tintColor = Theme.secondaryText
                    placeholder.contentMode = .scaleAspectFit
                    placeholder.translatesAutoresizingMaskIntoConstraints = false
                    self.pageImageView.addSubview(placeholder)
                    NSLayoutConstraint.activate([
                        placeholder.centerXAnchor.constraint(equalTo: self.pageImageView.centerXAnchor),
                        placeholder.centerYAnchor.constraint(equalTo: self.pageImageView.centerYAnchor),
                        placeholder.widthAnchor.constraint(equalToConstant: 32),
                        placeholder.heightAnchor.constraint(equalToConstant: 32)
                    ])
                }
                if let signals {
                    let refined = TrustScorer.assess(url: self.url, pageSignals: signals)
                    self.configureBadge(with: refined)
                    self.reasonsLabel.text = refined.reasons.map { "•  \($0)" }.joined(separator: "\n")
                }
            }
        }
    }

    private func configureBadge(with assessment: TrustAssessment) {
        badge.insets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        badge.text = "\(assessment.level.title) · \(assessment.score)"
        badge.font = .systemFont(ofSize: 12, weight: .bold)
        badge.textColor = .white
        badge.backgroundColor = assessment.level.color
        badge.layer.cornerRadius = 8
        badge.clipsToBounds = true
    }
}
