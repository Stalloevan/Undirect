import UIKit

protocol TabSidebarDelegate: AnyObject {
    func sidebarDidSelect(index: Int)
    func sidebarDidClose(index: Int)
    /// nil means "use the default (Settings.shared.torForNewTabs)".
    func sidebarDidRequestNewTab(tor: Bool?)
    /// Toggles exclusively between minimal and full — never touches hidden.
    func sidebarDidRequestToggleFull()
    func sidebarMenu(for index: Int) -> UIMenu?
    func sidebarStackMenu(for stackID: UUID) -> UIMenu?
    func sidebarDidRequestOverview()
}

struct SidebarItem {
    let icon: UIImage
    let title: String
    let isTor: Bool
    let isSelected: Bool
    let isLoading: Bool
    var stackID: UUID?
}

enum SidebarDisplayMode {
    /// A narrow column of icons only, no titles — every open tab, just compact.
    case minimal
    /// Full-width rows with titles and a close button.
    case full
}

private enum Row: Equatable {
    case tab(Int)
    case stackHeader(UUID)
    case addTab
}

/// The visible tab list, in one of two densities (the third, fully-hidden
/// state is handled outside this view — see BrowserContainerViewController's
/// floating pullout handle). The add-tab row sits right after the active
/// tab's row rather than pinned to the bottom.
final class TabSidebarView: UIView, UITableViewDataSource, UITableViewDelegate {

    static let minimalWidth: CGFloat = 52
    static let fullWidth: CGFloat = 250
    static let rowHeight: CGFloat = 48
    /// Where the tab list starts: toggle (4 + 34), overview button (34), gap (2).
    static let listTop: CGFloat = 74

    weak var delegate: TabSidebarDelegate?
    private(set) var mode: SidebarDisplayMode = .minimal

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let divider = UIView()
    private let toggleButton = UIButton(type: .system)
    private let overviewButton = UIButton(type: .system)

    private var items: [SidebarItem] = []
    private var rows: [Row] = []
    private var selectedTabIndex: Int? { items.firstIndex(where: \.isSelected) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.bar
        clipsToBounds = false

        toggleButton.tintColor = Theme.secondaryText
        toggleButton.addAction(UIAction { [weak self] _ in self?.delegate?.sidebarDidRequestToggleFull() }, for: .touchUpInside)

        overviewButton.tintColor = Theme.secondaryText
        overviewButton.setImage(Theme.icon("square.grid.2x2"), for: .normal)
        overviewButton.accessibilityLabel = "All tabs"
        overviewButton.addAction(UIAction { [weak self] _ in self?.delegate?.sidebarDidRequestOverview() }, for: .touchUpInside)

        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.showsVerticalScrollIndicator = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = Self.rowHeight
        tableView.register(TabCell.self, forCellReuseIdentifier: "tab")
        tableView.register(AddTabCell.self, forCellReuseIdentifier: "add")
        tableView.register(StackHeaderCell.self, forCellReuseIdentifier: "stack")

        divider.backgroundColor = UIColor(white: 1, alpha: 0.06)

        for v in [toggleButton, overviewButton, tableView, divider] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            toggleButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            toggleButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            toggleButton.widthAnchor.constraint(equalToConstant: Self.minimalWidth),
            toggleButton.heightAnchor.constraint(equalToConstant: 34),

            overviewButton.topAnchor.constraint(equalTo: toggleButton.bottomAnchor),
            overviewButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            overviewButton.widthAnchor.constraint(equalToConstant: Self.minimalWidth),
            overviewButton.heightAnchor.constraint(equalToConstant: 34),

            tableView.topAnchor.constraint(equalTo: overviewButton.bottomAnchor, constant: 2),
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

    /// Top edge (from the top of the sidebar) of the current tab's row, kept
    /// inside the visible part of the list. The hidden-state handle uses this
    /// so its icon lands exactly where the tab's own icon is in the bar.
    func selectedRowTop() -> CGFloat {
        var rowIndex = 0
        if let sel = selectedTabIndex {
            if let r = rows.firstIndex(of: .tab(sel)) { rowIndex = r }
            else if let sid = items[sel].stackID, let r = rows.firstIndex(of: .stackHeader(sid)) { rowIndex = r }
        }
        var y = Self.listTop + CGFloat(rowIndex) * Self.rowHeight - tableView.contentOffset.y
        y = max(Self.listTop, y)
        if bounds.height > Self.listTop + Self.rowHeight { y = min(y, bounds.height - Self.rowHeight) }
        return y
    }

    private func layoutRows() {
        // Group contiguous tabs that share a stack under a header; a collapsed
        // stack hides its members. The container keeps a stack's members
        // contiguous in tab order, so a simple run-length pass is enough.
        var built: [Row] = []
        var i = 0
        while i < items.count {
            if let sid = items[i].stackID {
                built.append(.stackHeader(sid))
                let collapsed = TabStackStore.shared.isCollapsed(sid)
                var j = i
                while j < items.count && items[j].stackID == sid {
                    if !collapsed { built.append(.tab(j)) }
                    j += 1
                }
                i = j
            } else {
                built.append(.tab(i))
                i += 1
            }
        }
        built.append(.addTab)
        rows = built

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
            cell.configure(item: items[index], compact: mode == .minimal, inStack: items[index].stackID != nil)
            cell.onClose = { [weak self] in self?.delegate?.sidebarDidClose(index: index) }
        case .stackHeader(let sid):
            guard let cell = cell as? StackHeaderCell else { return }
            let count = items.filter { $0.stackID == sid }.count
            let hasSelected = items.contains { $0.stackID == sid && $0.isSelected }
            cell.configure(name: TabStackStore.shared.name(sid), count: count,
                           collapsed: TabStackStore.shared.isCollapsed(sid),
                           containsSelected: hasSelected, compact: mode == .minimal)
            cell.onToggle = { [weak self] in
                TabStackStore.shared.toggleCollapsed(sid)
                self?.layoutRows()
            }
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
        case .stackHeader: identifier = "stack"
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
        case .stackHeader(let sid):
            TabStackStore.shared.toggleCollapsed(sid)
            layoutRows()
        case .addTab: delegate?.sidebarDidRequestNewTab(tor: nil)
        }
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        switch rows[indexPath.row] {
        case .tab(let index):
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in self?.delegate?.sidebarMenu(for: index) }
        case .stackHeader(let sid):
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in self?.delegate?.sidebarStackMenu(for: sid) }
        case .addTab:
            return nil
        }
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
    private var iconCenterX: NSLayoutConstraint!
    private var titleLeading: NSLayoutConstraint!
    private let stackRail = UIView()
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

        stackRail.backgroundColor = Theme.secondaryText.withAlphaComponent(0.25)
        stackRail.layer.cornerRadius = 1
        stackRail.isHidden = true

        for v in [stackRail, iconView, titleLabel, torBadge, closeButton, spinner] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(v)
        }
        iconCenterX = iconView.centerXAnchor.constraint(equalTo: contentView.leadingAnchor, constant: TabSidebarView.minimalWidth / 2)
        titleLeading = titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: TabSidebarView.minimalWidth)
        NSLayoutConstraint.activate([
            iconCenterX,
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 38),
            iconView.heightAnchor.constraint(equalToConstant: 38),

            stackRail.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            stackRail.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            stackRail.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            stackRail.widthAnchor.constraint(equalToConstant: 2),

            spinner.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            titleLeading,
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

    func configure(item: SidebarItem, compact: Bool, inStack: Bool = false) {
        let indent: CGFloat = (inStack && !compact) ? 16 : 0
        iconCenterX.constant = TabSidebarView.minimalWidth / 2 + indent
        titleLeading.constant = TabSidebarView.minimalWidth + indent
        stackRail.isHidden = !(inStack && !compact)
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

private final class StackHeaderCell: UITableViewCell {
    private let chevron = UIImageView()
    private let label = UILabel()
    private let countLabel = UILabel()
    var onToggle: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        chevron.tintColor = Theme.secondaryText
        chevron.contentMode = .scaleAspectFit
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingTail
        countLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        countLabel.textColor = Theme.secondaryText
        for v in [chevron, label, countLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(v)
        }
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            chevron.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 20),
            chevron.heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -6),
            countLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            countLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggle))
        contentView.addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggle() { onToggle?() }

    func configure(name: String, count: Int, collapsed: Bool, containsSelected: Bool, compact: Bool) {
        chevron.image = Theme.icon(collapsed ? "chevron.right" : "chevron.down", pointSize: 12, weight: .semibold)
        countLabel.text = "\(count)"
        countLabel.isHidden = compact
        if compact {
            label.text = ""
            label.isHidden = true
        } else {
            label.isHidden = false
            label.text = name
        }
        // A collapsed stack holding the current tab gets a faint highlight so
        // you can still see where you are.
        contentView.backgroundColor = (collapsed && containsSelected) ? Theme.field : .clear
        contentView.layer.cornerRadius = Theme.cornerRadius
        label.textColor = containsSelected ? Theme.accent : Theme.text
    }
}
