import UIKit

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

/// A local, offline heuristic — not a real security verdict. It never makes
/// a network request (an actual reputation lookup would mean phoning home
/// every link you hover, which is exactly the kind of tracking this browser
/// exists to avoid); it only reasons about the URL itself and what's already
/// known locally (the blocklist, your own whitelist).
enum TrustScorer {
    private static let riskyTLDs: Set<String> = [
        "tk", "ml", "ga", "cf", "gq", "xyz", "top", "click", "work", "link", "zip", "review"
    ]

    static func assess(url: URL) -> TrustAssessment {
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

        let labelCount = host.split(separator: ".").count
        if labelCount > 4 {
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

        if WhitelistStore.shared.isWhitelisted(host: host) {
            score += 15
            reasons.append("You've trusted this site")
        }

        score = max(0, min(100, score))
        let level: TrustLevel = score >= 70 ? .good : (score >= 40 ? .caution : .warning)
        if reasons.isEmpty { reasons = ["No notable risk signals found"] }
        return TrustAssessment(level: level, score: score, reasons: reasons)
    }
}

/// The custom preview shown above the long-press menu on a link, in place of
/// WebKit's default plain thumbnail.
final class LinkPreviewViewController: UIViewController {
    private let url: URL
    private let isTor: Bool

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

        let iconView = UIImageView(image: FaviconStore.shared.cached(host: url.host) ?? FaviconStore.monogram(for: url.host, tor: false))
        iconView.layer.cornerRadius = Theme.smallCornerRadius
        iconView.clipsToBounds = true
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 28).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let hostLabel = UILabel()
        hostLabel.text = host
        hostLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        hostLabel.textColor = Theme.text
        hostLabel.lineBreakMode = .byTruncatingMiddle

        let headerRow = UIStackView(arrangedSubviews: [iconView, hostLabel])
        headerRow.spacing = 8
        headerRow.alignment = .center

        let badge = PaddedLabel()
        badge.insets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        badge.text = "\(assessment.level.title) · \(assessment.score)"
        badge.font = .systemFont(ofSize: 12, weight: .bold)
        badge.textColor = .white
        badge.backgroundColor = assessment.level.color
        badge.layer.cornerRadius = 8
        badge.clipsToBounds = true

        let badgeRow = UIStackView(arrangedSubviews: [badge, UIView()])

        let reasonsLabel = UILabel()
        reasonsLabel.text = assessment.reasons.map { "•  \($0)" }.joined(separator: "\n")
        reasonsLabel.font = .systemFont(ofSize: 12)
        reasonsLabel.textColor = Theme.secondaryText
        reasonsLabel.numberOfLines = 0

        let disclaimer = UILabel()
        disclaimer.text = "Local heuristic, not a security guarantee — nothing about this link is sent anywhere to check it."
        disclaimer.font = .italicSystemFont(ofSize: 10)
        disclaimer.textColor = Theme.secondaryText
        disclaimer.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [headerRow, badgeRow, reasonsLabel, disclaimer])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14)
        ])

        view.setNeedsLayout()
        view.layoutIfNeeded()
        let height = stack.systemLayoutSizeFitting(CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)).height + 28
        preferredContentSize = CGSize(width: 300, height: height)

        if !isTor, let hostName = url.host {
            FaviconStore.shared.fetch(host: hostName, hint: nil) { [weak iconView] image in
                guard let image else { return }
                iconView?.image = image
            }
        }
    }
}
