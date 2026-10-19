import UIKit
import WebKit

/// A full-screen grid of every open tab — thumbnail, title, favicon — for
/// jumping between or closing tabs at a glance. Tabs in a stack show the
/// stack's name as a chip. Reached from the grid button in the tab bar.
final class TabOverviewViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {

    private var tabs: [Tab]
    private let initialSelected: Int
    private let onSelect: (Int) -> Void
    private let onClose: (Tab) -> Void
    private let onNewTab: () -> Void

    private var collectionView: UICollectionView!
    private var thumbnails: [UUID: UIImage] = [:]

    init(tabs: [Tab], selectedIndex: Int,
         onSelect: @escaping (Int) -> Void,
         onClose: @escaping (Tab) -> Void,
         onNewTab: @escaping () -> Void) {
        self.tabs = tabs
        self.initialSelected = selectedIndex
        self.onSelect = onSelect
        self.onClose = onClose
        self.onNewTab = onNewTab
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background

        let header = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        let title = UILabel()
        title.text = "\(tabs.count) Tab\(tabs.count == 1 ? "" : "s")"
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = Theme.text

        let done = UIButton(type: .system)
        done.setTitle("Done", for: .normal)
        done.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        done.tintColor = Theme.accent
        done.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)

        let add = UIButton(type: .system)
        add.setImage(Theme.icon("plus", pointSize: 20, weight: .semibold), for: .normal)
        add.tintColor = Theme.accent
        add.accessibilityLabel = "New Tab"
        add.addAction(UIAction { [weak self] _ in self?.onNewTab() }, for: .touchUpInside)

        for v in [title, done, add] { v.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(v) }

        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 14
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.contentInset = .init(top: 14, left: 16, bottom: 32, right: 16)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(TabOverviewCell.self, forCellWithReuseIdentifier: "tab")
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: safe.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 48),

            done.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            done.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            title.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            add.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            add.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            collectionView.topAnchor.constraint(equalTo: header.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        captureThumbnails()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if tabs.indices.contains(initialSelected) {
            collectionView.scrollToItem(at: IndexPath(item: initialSelected, section: 0), at: .centeredVertically, animated: false)
        }
    }

    /// The current tab gets a live snapshot; the rest reuse a stored history
    /// snapshot when there is one (placeholder otherwise — see the cell).
    private func captureThumbnails() {
        for (index, tab) in tabs.enumerated() {
            if let url = tab.url, let snap = tab.historySnapshot(for: url) {
                thumbnails[tab.id] = snap
            }
            if index == initialSelected, tab.webView.superview != nil {
                let config = WKSnapshotConfiguration()
                config.snapshotWidth = 400
                tab.webView.takeSnapshot(with: config) { [weak self] image, _ in
                    guard let self, let image else { return }
                    self.thumbnails[tab.id] = image
                    if let cell = self.collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? TabOverviewCell {
                        cell.setThumbnail(image)
                    }
                }
            }
        }
    }

    // MARK: Data source

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { tabs.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "tab", for: indexPath) as! TabOverviewCell
        let tab = tabs[indexPath.item]
        cell.configure(title: tab.title,
                       host: tab.host.map(DomainUtil.normalize) ?? "New Tab",
                       icon: tab.icon,
                       isTor: tab.isTor,
                       isCurrent: indexPath.item == initialSelected,
                       stackName: tab.stackID.map { TabStackStore.shared.name($0) },
                       placeholderColor: tab.pageBackgroundColor ?? Theme.surface,
                       thumbnail: thumbnails[tab.id])
        cell.onClose = { [weak self] in self?.closeTab(at: indexPath) }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onSelect(indexPath.item)
    }

    private func closeTab(at indexPath: IndexPath) {
        guard tabs.indices.contains(indexPath.item) else { return }
        let tab = tabs.remove(at: indexPath.item)
        onClose(tab)
        if tabs.isEmpty {
            dismiss(animated: true)
            return
        }
        collectionView.deleteItems(at: [indexPath])
        collectionView.reloadData()
    }

    // MARK: Layout

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let available = collectionView.bounds.width - collectionView.contentInset.left - collectionView.contentInset.right
        let columns: CGFloat = available > 540 ? 3 : 2
        let width = floor((available - 14 * (columns - 1)) / columns)
        return CGSize(width: width, height: width * 1.15 + 34)
    }
}

// MARK: - Cell

private final class TabOverviewCell: UICollectionViewCell {
    private let thumb = UIImageView()
    private let placeholderIcon = UIImageView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let torBadge = UIImageView(image: OnionIcon.image(pointSize: 12))
    private let closeButton = UIButton(type: .system)
    private let stackChip = PaddedLabel()
    var onClose: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = Theme.cornerRadius
        thumb.backgroundColor = Theme.surface
        thumb.layer.borderWidth = 1
        thumb.layer.borderColor = UIColor(white: 1, alpha: 0.08).cgColor

        placeholderIcon.contentMode = .scaleAspectFit
        placeholderIcon.alpha = 0.5

        iconView.layer.cornerRadius = 4
        iconView.clipsToBounds = true
        iconView.contentMode = .scaleAspectFill

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = Theme.text
        titleLabel.lineBreakMode = .byTruncatingTail

        torBadge.tintColor = Theme.tor
        torBadge.contentMode = .scaleAspectFit

        closeButton.setImage(Theme.icon("xmark.circle.fill", pointSize: 20), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor(white: 0, alpha: 0.35)
        closeButton.layer.cornerRadius = 11
        closeButton.clipsToBounds = true
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)

        stackChip.font = .systemFont(ofSize: 10, weight: .semibold)
        stackChip.textColor = .white
        stackChip.backgroundColor = Theme.accent
        stackChip.layer.cornerRadius = 5
        stackChip.clipsToBounds = true
        stackChip.insets = UIEdgeInsets(top: 1, left: 5, bottom: 1, right: 5)

        for v in [thumb, placeholderIcon, iconView, titleLabel, torBadge, closeButton, stackChip] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(v)
        }
        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: contentView.topAnchor),
            thumb.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            thumb.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            thumb.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -30),

            placeholderIcon.centerXAnchor.constraint(equalTo: thumb.centerXAnchor),
            placeholderIcon.centerYAnchor.constraint(equalTo: thumb.centerYAnchor),
            placeholderIcon.widthAnchor.constraint(equalToConstant: 40),
            placeholderIcon.heightAnchor.constraint(equalToConstant: 40),

            closeButton.topAnchor.constraint(equalTo: thumb.topAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: -6),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),

            stackChip.topAnchor.constraint(equalTo: thumb.topAnchor, constant: 6),
            stackChip.leadingAnchor.constraint(equalTo: thumb.leadingAnchor, constant: 6),

            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            iconView.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 8),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: torBadge.leadingAnchor, constant: -4),

            torBadge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
            torBadge.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            torBadge.widthAnchor.constraint(equalToConstant: 13),
            torBadge.heightAnchor.constraint(equalToConstant: 13)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, host: String, icon: UIImage, isTor: Bool, isCurrent: Bool,
                   stackName: String?, placeholderColor: UIColor, thumbnail: UIImage?) {
        titleLabel.text = title.isEmpty ? host : title
        iconView.image = icon
        torBadge.isHidden = !isTor
        thumb.layer.borderColor = (isCurrent ? Theme.accent : UIColor(white: 1, alpha: 0.08)).cgColor
        thumb.layer.borderWidth = isCurrent ? 2 : 1
        if let stackName {
            stackChip.text = stackName.uppercased()
            stackChip.isHidden = false
        } else {
            stackChip.isHidden = true
        }
        setThumbnail(thumbnail, placeholderColor: placeholderColor, icon: icon)
    }

    func setThumbnail(_ image: UIImage?, placeholderColor: UIColor? = nil, icon: UIImage? = nil) {
        if let image {
            thumb.image = image
            placeholderIcon.isHidden = true
        } else {
            thumb.image = nil
            if let placeholderColor { thumb.backgroundColor = placeholderColor }
            placeholderIcon.image = icon
            placeholderIcon.isHidden = false
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumb.image = nil
        placeholderIcon.isHidden = true
    }
}
