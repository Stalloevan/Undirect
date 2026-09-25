import UIKit

final class NewTabPageViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {

    var onOpen: ((URL, _ newTab: Bool, _ tor: Bool) -> Void)?
    var onNewTorTab: (() -> Void)?
    var onCustomize: (() -> Void)?

    private var collectionView: UICollectionView!
    private var sections: [NTPSection] = []
    private var favorites: [FavoriteSite] = []
    private var reloadScheduled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(FavoriteCell.self, forCellWithReuseIdentifier: "fav")
        collectionView.register(StatsCell.self, forCellWithReuseIdentifier: "stats")
        collectionView.register(TorCell.self, forCellWithReuseIdentifier: "tor")
        collectionView.register(EmptyCell.self, forCellWithReuseIdentifier: "empty")
        collectionView.register(HeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "header")
        view.addSubview(collectionView)

        let nc = NotificationCenter.default
        for name in [Settings.didChange, FavoritesStore.didChange, BlockStats.didChange, TorManager.stateDidChange] {
            nc.addObserver(self, selector: #selector(scheduleReload), name: name, object: nil)
        }
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    @objc private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.reloadScheduled = false
            self?.reload()
        }
    }

    func reload() {
        guard isViewLoaded else { return }
        sections = Settings.shared.ntpVisibleSections
        favorites = FavoritesStore.shared.all()
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        collectionView.reloadData()
    }

    // MARK: Layout

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, env in
            guard let self, self.sections.indices.contains(index) else { return nil }
            let section: NSCollectionLayoutSection
            switch self.sections[index] {
            case .favorites where !self.favorites.isEmpty:
                let columns = Settings.shared.ntpColumns
                let itemHeight: CGFloat = Settings.shared.ntpShowTitles ? 86 : 64
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1 / CGFloat(columns)),
                                                                    heightDimension: .absolute(itemHeight)))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                                                 heightDimension: .absolute(itemHeight)),
                                                               subitems: [item])
                section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = 6
            default:
                let height: CGFloat
                switch self.sections[index] {
                case .stats: height = Settings.shared.ntpDetailedStats ? 176 : 72
                case .tor: height = 72
                case .favorites: height = 72
                }
                let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
                section = NSCollectionLayoutSection(group: group)
            }
            section.contentInsets = .init(top: 6, leading: 16, bottom: 18, trailing: 16)
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(34)),
                elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
            section.boundarySupplementaryItems = [header]
            _ = env
            return section
        }
    }

    // MARK: Data source

    func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        switch sections[section] {
        case .favorites: return max(favorites.count, 1)
        case .stats, .tor: return 1
        }
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        switch sections[indexPath.section] {
        case .favorites:
            guard !favorites.isEmpty else {
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "empty", for: indexPath) as! EmptyCell
                cell.label.text = "Tap ☆ on any page to pin it here."
                return cell
            }
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "fav", for: indexPath) as! FavoriteCell
            let fav = favorites[indexPath.item]
            let host = URL(string: fav.urlString)?.host
            cell.configure(title: fav.title.isEmpty ? (host ?? fav.urlString) : fav.title,
                           icon: FaviconStore.shared.cached(host: host) ?? FaviconStore.monogram(for: host, tor: false),
                           showTitle: Settings.shared.ntpShowTitles)
            if FaviconStore.shared.cached(host: host) == nil, let host {
                FaviconStore.shared.fetch(host: host, hint: nil) { [weak collectionView] image in
                    guard image != nil, let collectionView,
                          collectionView.indexPathsForVisibleItems.contains(indexPath) else { return }
                    collectionView.reloadItems(at: [indexPath])
                }
            }
            return cell
        case .stats:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "stats", for: indexPath) as! StatsCell
            cell.configure(detailed: Settings.shared.ntpDetailedStats)
            return cell
        case .tor:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "tor", for: indexPath) as! TorCell
            cell.configure(state: TorManager.shared.state)
            cell.onOpen = { [weak self] in self?.onNewTorTab?() }
            return cell
        }
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "header", for: indexPath) as! HeaderView
        header.label.text = sections[indexPath.section].title.uppercased()
        header.button.isHidden = indexPath.section != 0
        header.onButton = { [weak self] in self?.onCustomize?() }
        return header
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard sections[indexPath.section] == .favorites, favorites.indices.contains(indexPath.item),
              let url = URL(string: favorites[indexPath.item].urlString) else { return }
        onOpen?(url, false, false)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath,
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard sections[indexPath.section] == .favorites, favorites.indices.contains(indexPath.item),
              let url = URL(string: favorites[indexPath.item].urlString) else { return nil }
        let fav = favorites[indexPath.item]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "Open in New Tab", image: UIImage(systemName: "plus.square.on.square")) { _ in
                    self?.onOpen?(url, true, false)
                },
                UIAction(title: "Open in Tor Tab", image: OnionIcon.image(pointSize: 18)) { _ in
                    self?.onOpen?(url, true, true)
                },
                UIAction(title: "Remove", image: UIImage(systemName: "star.slash"), attributes: .destructive) { _ in
                    FavoritesStore.shared.remove(urlString: fav.urlString)
                }
            ])
        }
    }
}

// MARK: - Cells

private final class HeaderView: UICollectionReusableView {
    let label = UILabel()
    let button = UIButton(type: .system)
    var onButton: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = Theme.secondaryText
        button.setImage(UIImage(systemName: "slider.horizontal.3"), for: .normal)
        button.tintColor = Theme.secondaryText
        button.accessibilityLabel = "Customize new tab page"
        button.addAction(UIAction { [weak self] _ in self?.onButton?() }, for: .touchUpInside)
        for v in [label, button] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 36),
            button.heightAnchor.constraint(equalToConstant: 30)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class FavoriteCell: UICollectionViewCell {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.layer.cornerRadius = Theme.smallCornerRadius + 5
        iconView.clipsToBounds = true
        iconView.contentMode = .scaleAspectFill
        iconView.backgroundColor = Theme.surface
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = Theme.secondaryText
        titleLabel.textAlignment = .center
        for v in [iconView, titleLabel] { v.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(v) }
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 52),
            iconView.heightAnchor.constraint(equalToConstant: 52),
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 5),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, icon: UIImage, showTitle: Bool) {
        iconView.image = icon
        titleLabel.text = title
        titleLabel.isHidden = !showTitle
        accessibilityLabel = title
        isAccessibilityElement = true
    }
}

private final class EmptyCell: UICollectionViewCell {
    let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Theme.surface
        contentView.layer.cornerRadius = Theme.cornerRadius + 3
        label.font = .systemFont(ofSize: 14)
        label.textColor = Theme.secondaryText
        label.textAlignment = .center
        label.numberOfLines = 0
        label.frame = contentView.bounds.insetBy(dx: 12, dy: 8)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class StatsCell: UICollectionViewCell {
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Theme.surface
        contentView.layer.cornerRadius = Theme.cornerRadius + 3
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(detailed: Bool) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let stats = BlockStats.shared
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal

        let total = UILabel()
        total.attributedText = {
            let s = NSMutableAttributedString(string: formatter.string(from: NSNumber(value: stats.total)) ?? "0",
                                              attributes: [.font: UIFont.systemFont(ofSize: 30, weight: .bold),
                                                           .foregroundColor: Theme.accent])
            let since = DateFormatter.localizedString(from: stats.since, dateStyle: .medium, timeStyle: .none)
            s.append(NSAttributedString(string: "  blocked since \(since)",
                                        attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: Theme.secondaryText]))
            return s
        }()
        stack.addArrangedSubview(total)
        guard detailed else { return }

        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 8
        let kinds = StatKind.allCases
        for rowStart in stride(from: 0, to: kinds.count, by: 2) {
            let row = UIStackView()
            row.distribution = .fillEqually
            row.spacing = 8
            for kind in kinds[rowStart..<min(rowStart + 2, kinds.count)] {
                row.addArrangedSubview(Self.statView(kind, value: formatter.string(from: NSNumber(value: stats.count(kind))) ?? "0"))
            }
            if row.arrangedSubviews.count == 1 { row.addArrangedSubview(UIView()) }
            grid.addArrangedSubview(row)
        }
        stack.addArrangedSubview(grid)
    }

    private static func statView(_ kind: StatKind, value: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: kind.symbol))
        icon.tintColor = Theme.secondaryText
        icon.contentMode = .scaleAspectFit
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let label = UILabel()
        label.font = .systemFont(ofSize: 13)
        label.textColor = Theme.text
        label.text = "\(value) \(kind.title.lowercased())"
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        let row = UIStackView(arrangedSubviews: [icon, label])
        row.spacing = 6
        return row
    }
}

private final class TorCell: UICollectionViewCell {
    private let status = UILabel()
    private let button = UIButton(type: .system)
    var onOpen: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Theme.surface
        contentView.layer.cornerRadius = Theme.cornerRadius + 3
        status.font = .systemFont(ofSize: 14, weight: .medium)
        status.textColor = Theme.text
        status.numberOfLines = 2
        var config = UIButton.Configuration.filled()
        config.title = "New Tor Tab"
        config.baseBackgroundColor = Theme.tor
        config.cornerStyle = .capsule
        config.image = OnionIcon.image(pointSize: 16)
        config.imagePadding = 6
        button.configuration = config
        button.addAction(UIAction { [weak self] _ in self?.onOpen?() }, for: .touchUpInside)
        for v in [status, button] { v.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(v) }
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            status.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            button.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(state: TorManager.State) {
        status.text = "Tor: " + state.description
    }
}
