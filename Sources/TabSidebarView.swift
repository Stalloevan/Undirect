import UIKit

protocol TabSidebarDelegate: AnyObject {
    func sidebarDidSelect(index: Int)
    func sidebarDidClose(index: Int)
    /// nil means "use the default (Settings.shared.torForNewTabs)".
    func sidebarDidRequestNewTab(tor: Bool?)
    /// Toggles exclusively between minimal and full — never touches hidden.
    func sidebarDidRequestToggleFull()
    func sidebarMenu(for index: Int) -> UIMenu?
}

struct SidebarItem {
    let icon: UIImage
    let title: String
    let isTor: Bool
    let isSelected: Bool
    let isLoading: Bool
}

enum SidebarDisplayMode {
    /// A narrow column of icons only, no titles — every open tab, just compact.
    case minimal
    /// Full-width rows with titles and a close button.
    case full
}

private enum Row: Equatable {
    case tab(Int)
    case addTab
}

/// The visible tab list, in one of two densities (the third, fully-hidden
/// state is handled outside this view — see BrowserContainerViewController's
/// floating pullout handle). The add-tab row sits right after the active
/// tab's row rather than pinned to the bottom.
final class TabSidebarView: UIView, UITableViewDataSource, UITableViewDelegate {

    static let minimalWidth: CGFloat = 52
    static let fullWidth: CGFloat = 250

    weak var delegate: TabSidebarDelegate?
    private(set) var mode: SidebarDisplayMode = .minimal

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let divider = UIView()
    private let toggleButton = UIButton(type: .system)

    private var items: [SidebarItem] = []
    private var rows: [Row] = []
    private var selectedTabIndex: Int? { items.firstIndex(where: \.isSelected) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.bar
        clipsToBounds = false

        toggleButton.tintColor = Theme.secondaryText
        toggleButton.addAction(UIAction { [weak self] _ in self?.delegate?.sidebarDidRequestToggleFull() }, for: .touchUpInside)

        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.showsVerticalScrollIndicator = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 48
        tableView.register(TabCell.self, forCellReuseIdentifier: "tab")
        tableView.register(AddTabCell.self, forCellReuseIdentifier: "add")

        divider.backgroundColor = UIColor(white: 1, alpha: 0.06)

        for v in [toggleButton, tableView, divider] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            toggleButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            toggleButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            toggleButton.widthAnchor.constraint(equalToConstant: Self.minimalWidth),
            toggleButton.heightAnchor.constraint(equalToConstant: 34),

            tableView.topAnchor.constraint(equalTo: toggleButton.bottomAnchor, constant: 2),
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),

            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1)
        ])

        updateToggleIcon()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateToggleIcon() {
        toggleButton.setImage(Theme.icon(mode == .full ? "sidebar.leading" : "sidebar.left"), for: .normal)
        toggleButton.accessibilityLabel = mode == .full ? "Show fewer tab details" : "Show tab names"
    }

    func setMode(_ mode: SidebarDisplayMode) {
        self.mode = mode
        updateToggleIcon()
        tableView.reloadData()
    }

    func update(items: [SidebarItem]) {
        self.items = items
        layoutRows()
    }

    private func layoutRows() {
        rows = items.indices.map { .tab($0) } + [.addTab]

        tableView.reloadData()
        if let selected = selectedTabIndex, let rowIndex = rows.firstIndex(of: .tab(selected)) {
            let ip = IndexPath(row: rowIndex, section: 0)
            if !(tableView.indexPathsForVisibleRows ?? []).contains(ip) {
                tableView.scrollToRow(at: ip, at: .middle, animated: false)
            }
        }
    }

    private func configure(_ cell: UITableViewCell, at row: Int) {
        switch rows[row] {
        case .tab(let index):
            guard let cell = cell as? TabCell, items.indices.contains(index) else { return }
            cell.configure(item: items[index], compact: mode == .minimal)
            cell.onClose = { [weak self] in self?.delegate?.sidebarDidClose(index: index) }
        case .addTab:
            guard let cell = cell as? AddTabCell else { return }
            cell.configure(compact: mode == .minimal)
            cell.onTap = { [weak self] in self?.delegate?.sidebarDidRequestNewTab(tor: nil) }
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let identifier: String
        switch rows[indexPath.row] {
        case .tab: identifier = "tab"
        case .addTab: identifier = "add"
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier, for: indexPath)
        configure(cell, at: indexPath.row)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        switch rows[indexPath.row] {
        case .tab(let index): delegate?.sidebarDidSelect(index: index)
        case .addTab: delegate?.sidebarDidRequestNewTab(tor: nil)
        }
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard case .tab(let index) = rows[indexPath.row] else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in self?.delegate?.sidebarMenu(for: index) }
    }
}

// MARK: - Cells

private final class TabCell: UITableViewCell {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let torBadge = UIImageView(image: OnionIcon.image(pointSize: 14))
    private let closeButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var isSelectedTab = false
    var onClose: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        contentView.layer.cornerRadius = Theme.cornerRadius
        contentView.clipsToBounds = true

        iconView.layer.cornerRadius = Theme.smallCornerRadius
        iconView.clipsToBounds = true
        iconView.contentMode = .scaleAspectFill
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = Theme.text
        torBadge.tintColor = Theme.tor
        torBadge.contentMode = .scaleAspectFit
        closeButton.setImage(Theme.icon("xmark"), for: .normal)
        closeButton.tintColor = Theme.secondaryText
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        spinner.color = Theme.secondaryText
        spinner.hidesWhenStopped = true

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        contentView.addGestureRecognizer(doubleTap)
        accessibilityHint = "Double-tap to close"

        for v in [iconView, titleLabel, torBadge, closeButton, spinner] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(v)
        }
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: contentView.leadingAnchor, constant: TabSidebarView.minimalWidth / 2),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 38),
            iconView.heightAnchor.constraint(equalToConstant: 38),

            spinner.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: TabSidebarView.minimalWidth),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: torBadge.leadingAnchor, constant: -6),

            torBadge.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            torBadge.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            torBadge.widthAnchor.constraint(equalToConstant: 16),
            torBadge.heightAnchor.constraint(equalToConstant: 16),

            closeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func handleDoubleTap() { onClose?() }

    func configure(item: SidebarItem, compact: Bool) {
        iconView.image = item.icon
        iconView.alpha = item.isLoading ? 0.35 : 1
        if item.isLoading { spinner.startAnimating() } else { spinner.stopAnimating() }
        titleLabel.text = item.title
        titleLabel.isHidden = compact
        // The onion indicator appears only in full (titled) mode; the minimal
        // icon-only column stays clean.
        torBadge.isHidden = compact || !item.isTor
        closeButton.isHidden = compact
        accessibilityLabel = (item.isTor ? "Tor tab: " : "Tab: ") + item.title

        // Only the current tab gets any background at all; every other tab
        // sits flush against the sidebar with no fill of its own.
        isSelectedTab = item.isSelected
        contentView.backgroundColor = item.isSelected ? Theme.field : .clear
        if item.isSelected { Theme.applyBlockShadow(to: contentView) } else { contentView.layer.shadowOpacity = 0 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if isSelectedTab { Theme.applyBlockShadow(to: contentView) } else { contentView.layer.shadowOpacity = 0 }
    }
}

private final class AddTabCell: UITableViewCell {
    private let button = UIButton(type: .system)
    var onTap: (() -> Void)? {
        didSet { button.removeTarget(nil, action: nil, for: .allEvents); button.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside) }
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        button.tintColor = Theme.accent
        button.contentHorizontalAlignment = .leading
        button.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(compact: Bool) {
        var config = UIButton.Configuration.plain()
        config.image = Theme.icon("plus")
        config.baseForegroundColor = Theme.accent
        if compact {
            config.contentInsets = .init(top: 0, leading: (TabSidebarView.minimalWidth - 22) / 2, bottom: 0, trailing: 0)
        } else {
            config.title = "New Tab"
            config.imagePadding = 10
            config.contentInsets = .init(top: 0, leading: TabSidebarView.minimalWidth - 22, bottom: 0, trailing: 0)
            config.titleAlignment = .leading
        }
        button.configuration = config
    }
}
