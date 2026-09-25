import UIKit

protocol TabSidebarDelegate: AnyObject {
    func sidebarDidSelect(index: Int)
    func sidebarDidClose(index: Int)
    /// nil means "use the default (Settings.shared.torForNewTabs)".
    func sidebarDidRequestNewTab(tor: Bool?)
    func sidebarDidToggleExpanded()
    func sidebarMenu(for index: Int) -> UIMenu?
}

struct SidebarItem {
    let icon: UIImage
    let title: String
    let isTor: Bool
    let isSelected: Bool
    let isLoading: Bool
}

private enum Row: Equatable {
    case tab(Int)
    case addTab
}

/// Collapsed: a single icon for the current tab, with an add-tab button
/// directly beneath it — not a column of every open tab.
/// Expanded: the full tab list, with the add-tab row inserted right after
/// whichever tab is active (not pinned to the bottom).
final class TabSidebarView: UIView, UITableViewDataSource, UITableViewDelegate {

    static let collapsedWidth: CGFloat = 52
    static let expandedWidth: CGFloat = 250

    weak var delegate: TabSidebarDelegate?
    private(set) var isExpanded = false

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let divider = UIView()

    // Collapsed-mode controls
    private let collapsedStack = UIStackView()
    private let currentTabButton = UIButton(type: .system)
    private let currentTabIcon = UIImageView()
    private let currentTabSpinner = UIActivityIndicatorView(style: .medium)
    private let collapsedAddButton = UIButton(type: .system)
    private var currentTabInteraction: UIContextMenuInteraction?

    private var items: [SidebarItem] = []
    private var rows: [Row] = []
    private var selectedTabIndex: Int? { items.firstIndex(where: \.isSelected) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.bar
        clipsToBounds = false

        // Collapsed: current-tab icon (tap to expand, long-press for actions), add button below.
        currentTabIcon.contentMode = .scaleAspectFill
        currentTabIcon.layer.cornerRadius = 8
        currentTabIcon.clipsToBounds = true
        currentTabSpinner.color = Theme.secondaryText
        currentTabSpinner.hidesWhenStopped = true
        currentTabButton.addAction(UIAction { [weak self] _ in self?.delegate?.sidebarDidToggleExpanded() }, for: .touchUpInside)
        currentTabButton.accessibilityLabel = "Current tab — tap to show all tabs"
        let interaction = UIContextMenuInteraction(delegate: self)
        currentTabButton.addInteraction(interaction)
        currentTabInteraction = interaction

        collapsedAddButton.setImage(UIImage(systemName: "plus"), for: .normal)
        collapsedAddButton.tintColor = Theme.accent
        collapsedAddButton.accessibilityLabel = "New tab"
        collapsedAddButton.addAction(UIAction { [weak self] _ in self?.delegate?.sidebarDidRequestNewTab(tor: nil) }, for: .touchUpInside)
        collapsedAddButton.menu = newTabMenu()
        collapsedAddButton.showsMenuAsPrimaryAction = false

        collapsedStack.axis = .vertical
        collapsedStack.alignment = .center
        collapsedStack.spacing = 6

        for v in [currentTabIcon, currentTabSpinner] { v.translatesAutoresizingMaskIntoConstraints = false; currentTabButton.addSubview(v) }
        NSLayoutConstraint.activate([
            currentTabIcon.centerXAnchor.constraint(equalTo: currentTabButton.centerXAnchor),
            currentTabIcon.centerYAnchor.constraint(equalTo: currentTabButton.centerYAnchor),
            currentTabIcon.widthAnchor.constraint(equalToConstant: 30),
            currentTabIcon.heightAnchor.constraint(equalToConstant: 30),
            currentTabSpinner.centerXAnchor.constraint(equalTo: currentTabIcon.centerXAnchor),
            currentTabSpinner.centerYAnchor.constraint(equalTo: currentTabIcon.centerYAnchor)
        ])
        currentTabButton.translatesAutoresizingMaskIntoConstraints = false
        currentTabButton.widthAnchor.constraint(equalToConstant: Self.collapsedWidth).isActive = true
        currentTabButton.heightAnchor.constraint(equalToConstant: Self.collapsedWidth).isActive = true
        collapsedStack.addArrangedSubview(currentTabButton)
        collapsedStack.addArrangedSubview(collapsedAddButton)

        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.showsVerticalScrollIndicator = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 48
        tableView.register(TabCell.self, forCellReuseIdentifier: "tab")
        tableView.register(AddTabCell.self, forCellReuseIdentifier: "add")

        divider.backgroundColor = UIColor(white: 1, alpha: 0.06)

        for v in [collapsedStack, tableView, divider] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            collapsedStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            collapsedStack.centerXAnchor.constraint(equalTo: centerXAnchor),

            tableView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),

            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func newTabMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "New Tab", image: UIImage(systemName: "plus.square")) { [weak self] _ in
                self?.delegate?.sidebarDidRequestNewTab(tor: false)
            },
            UIAction(title: "New Tor Tab", image: OnionIcon.image(pointSize: 18)) { [weak self] _ in
                self?.delegate?.sidebarDidRequestNewTab(tor: true)
            }
        ])
    }

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        collapsedStack.isHidden = expanded
        tableView.isHidden = !expanded
        if expanded { tableView.reloadData() }
        layoutRows()
    }

    func update(items: [SidebarItem]) {
        self.items = items
        layoutRows()

        // Collapsed-mode current tab display.
        if let tab = items.first(where: \.isSelected) {
            currentTabIcon.image = tab.icon
            currentTabIcon.layer.borderWidth = tab.isTor ? 2 : 0
            currentTabIcon.layer.borderColor = Theme.tor.cgColor
            currentTabIcon.alpha = tab.isLoading ? 0.35 : 1
            if tab.isLoading { currentTabSpinner.startAnimating() } else { currentTabSpinner.stopAnimating() }
            currentTabButton.accessibilityLabel = (tab.isTor ? "Tor tab: " : "Tab: ") + tab.title
        }
    }

    private func layoutRows() {
        let previousCount = rows.count
        var newRows: [Row] = []
        for i in items.indices {
            newRows.append(.tab(i))
            if i == (selectedTabIndex ?? -1) { newRows.append(.addTab) }
        }
        if selectedTabIndex == nil { newRows.append(.addTab) }
        rows = newRows

        guard isExpanded else { return }
        if rows.count != previousCount {
            tableView.reloadData()
        } else {
            for cell in tableView.visibleCells {
                guard let ip = tableView.indexPath(for: cell) else { continue }
                configure(cell, at: ip.row)
            }
        }
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
            cell.configure(item: items[index])
            cell.onClose = { [weak self] in self?.delegate?.sidebarDidClose(index: index) }
        case .addTab:
            (cell as? AddTabCell)?.onTap = { [weak self] in self?.delegate?.sidebarDidRequestNewTab(tor: nil) }
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

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard case .tab(let index) = rows[indexPath.row] else { return nil }
        let close = UIContextualAction(style: .destructive, title: "Close") { [weak self] _, _, done in
            self?.delegate?.sidebarDidClose(index: index)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [close])
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard case .tab(let index) = rows[indexPath.row] else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in self?.delegate?.sidebarMenu(for: index) }
    }
}

extension TabSidebarView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let index = selectedTabIndex else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in self?.delegate?.sidebarMenu(for: index) }
    }
}

// MARK: - Cells

private final class TabCell: UITableViewCell {
    private let highlight = UIView()
    private let iconView = UIImageView()
    private let ring = UIView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    var onClose: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        highlight.layer.cornerRadius = 10
        iconView.layer.cornerRadius = 7
        iconView.clipsToBounds = true
        iconView.contentMode = .scaleAspectFill
        ring.layer.cornerRadius = 9
        ring.layer.borderWidth = 2
        ring.layer.borderColor = Theme.tor.cgColor
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = Theme.text
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = Theme.secondaryText
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        spinner.color = Theme.secondaryText
        spinner.hidesWhenStopped = true

        for v in [highlight, ring, iconView, titleLabel, closeButton, spinner] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(v)
        }
        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 5),
            highlight.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5),
            highlight.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            highlight.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),

            iconView.centerXAnchor.constraint(equalTo: contentView.leadingAnchor, constant: TabSidebarView.collapsedWidth / 2),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),

            ring.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            ring.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: 32),
            ring.heightAnchor.constraint(equalToConstant: 32),

            spinner.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: TabSidebarView.collapsedWidth),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),

            closeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(item: SidebarItem) {
        iconView.image = item.icon
        iconView.alpha = item.isLoading ? 0.35 : 1
        if item.isLoading { spinner.startAnimating() } else { spinner.stopAnimating() }
        ring.isHidden = !item.isTor
        highlight.backgroundColor = item.isSelected ? Theme.field : .clear
        titleLabel.text = item.title
        accessibilityLabel = (item.isTor ? "Tor tab: " : "Tab: ") + item.title
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
        var config = UIButton.Configuration.plain()
        config.title = "New Tab"
        config.image = UIImage(systemName: "plus")
        config.imagePadding = 10
        config.baseForegroundColor = Theme.accent
        config.contentInsets = .init(top: 0, leading: TabSidebarView.collapsedWidth - 22, bottom: 0, trailing: 0)
        config.titleAlignment = .leading
        button.configuration = config
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
}
