import UIKit

protocol TabSidebarDelegate: AnyObject {
    func sidebarDidSelect(index: Int)
    func sidebarDidClose(index: Int)
    func sidebarDidRequestNewTab(tor: Bool)
    func sidebarDidToggleExpanded()
    func sidebarDidRequestCloseOthers(index: Int)
}

struct SidebarItem {
    let icon: UIImage
    let title: String
    let isTor: Bool
    let isSelected: Bool
    let isLoading: Bool
}

final class TabSidebarView: UIView, UITableViewDataSource, UITableViewDelegate {

    static let collapsedWidth: CGFloat = 52
    static let expandedWidth: CGFloat = 250

    weak var delegate: TabSidebarDelegate?
    private(set) var isExpanded = false

    private let toggleButton = UIButton(type: .system)
    private let addButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let divider = UIView()
    private var items: [SidebarItem] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.bar
        clipsToBounds = false

        toggleButton.setImage(UIImage(systemName: "sidebar.left"), for: .normal)
        toggleButton.tintColor = Theme.secondaryText
        toggleButton.addAction(UIAction { [weak self] _ in self?.delegate?.sidebarDidToggleExpanded() }, for: .touchUpInside)
        toggleButton.accessibilityLabel = "Show tab titles"

        addButton.setImage(UIImage(systemName: "plus"), for: .normal)
        addButton.tintColor = Theme.accent
        addButton.accessibilityLabel = "New tab"
        addButton.addAction(UIAction { [weak self] _ in self?.delegate?.sidebarDidRequestNewTab(tor: false) }, for: .touchUpInside)
        addButton.menu = UIMenu(children: [
            UIAction(title: "New Tab", image: UIImage(systemName: "plus.square")) { [weak self] _ in
                self?.delegate?.sidebarDidRequestNewTab(tor: false)
            },
            UIAction(title: "New Tor Tab", image: UIImage(systemName: "network.badge.shield.half.filled")) { [weak self] _ in
                self?.delegate?.sidebarDidRequestNewTab(tor: true)
            }
        ])

        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.showsVerticalScrollIndicator = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 48
        tableView.register(TabCell.self, forCellReuseIdentifier: "tab")

        divider.backgroundColor = UIColor(white: 1, alpha: 0.06)

        for v in [toggleButton, addButton, tableView, divider] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            toggleButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            toggleButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            toggleButton.widthAnchor.constraint(equalToConstant: Self.collapsedWidth),
            toggleButton.heightAnchor.constraint(equalToConstant: 40),

            tableView.topAnchor.constraint(equalTo: toggleButton.bottomAnchor, constant: 2),
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -2),

            addButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            addButton.widthAnchor.constraint(equalToConstant: Self.collapsedWidth),
            addButton.heightAnchor.constraint(equalToConstant: 44),
            addButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        toggleButton.setImage(UIImage(systemName: expanded ? "sidebar.leading" : "sidebar.left"), for: .normal)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = expanded ? 0.5 : 0
        layer.shadowRadius = 12
        tableView.reloadData()
    }

    func update(items: [SidebarItem]) {
        let structureChanged = items.count != self.items.count
        self.items = items
        if structureChanged {
            tableView.reloadData()
        } else {
            for cell in tableView.visibleCells {
                guard let cell = cell as? TabCell, let ip = tableView.indexPath(for: cell), items.indices.contains(ip.row) else { continue }
                configure(cell, at: ip.row)
            }
        }
        if let selected = items.firstIndex(where: \.isSelected) {
            let ip = IndexPath(row: selected, section: 0)
            if !(tableView.indexPathsForVisibleRows ?? []).contains(ip) {
                tableView.scrollToRow(at: ip, at: .middle, animated: false)
            }
        }
    }

    private func configure(_ cell: TabCell, at row: Int) {
        let item = items[row]
        cell.configure(item: item, expanded: isExpanded)
        cell.onClose = { [weak self, weak cell] in
            guard let self, let cell, let ip = self.tableView.indexPath(for: cell) else { return }
            self.delegate?.sidebarDidClose(index: ip.row)
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "tab", for: indexPath) as! TabCell
        configure(cell, at: indexPath.row)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        delegate?.sidebarDidSelect(index: indexPath.row)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard isExpanded else { return nil }
        let close = UIContextualAction(style: .destructive, title: "Close") { [weak self] _, _, done in
            self?.delegate?.sidebarDidClose(index: indexPath.row)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [close])
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "Close Tab", image: UIImage(systemName: "xmark"), attributes: .destructive) { _ in
                    self?.delegate?.sidebarDidClose(index: indexPath.row)
                },
                UIAction(title: "Close Other Tabs", image: UIImage(systemName: "xmark.square")) { _ in
                    self?.delegate?.sidebarDidRequestCloseOthers(index: indexPath.row)
                }
            ])
        }
    }
}

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

    func configure(item: SidebarItem, expanded: Bool) {
        iconView.image = item.icon
        iconView.alpha = item.isLoading ? 0.35 : 1
        if item.isLoading { spinner.startAnimating() } else { spinner.stopAnimating() }
        ring.isHidden = !item.isTor
        highlight.backgroundColor = item.isSelected ? Theme.field : .clear
        titleLabel.text = item.title
        titleLabel.isHidden = !expanded
        closeButton.isHidden = !expanded
        accessibilityLabel = (item.isTor ? "Tor tab: " : "Tab: ") + item.title
    }
}
