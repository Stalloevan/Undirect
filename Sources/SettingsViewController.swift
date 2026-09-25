import UIKit

// MARK: - Generic settings table

struct SettingsRow {
    enum Kind {
        case toggle(get: () -> Bool, set: (Bool) -> Void)
        case choice(value: () -> String, options: () -> [(String, () -> Void)])
        case action(() -> Void)
        case push(() -> UIViewController)
        case info(() -> String)
    }
    let title: String
    let kind: Kind
    var destructive = false
}

struct SettingsSection {
    let title: String?
    let footer: String?
    let rows: [SettingsRow]
}

class SettingsTableViewController: UITableViewController {
    var sections: [SettingsSection] = []

    init() { super.init(style: Theme.tableViewStyle) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        tableView.backgroundColor = Theme.background
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        navigationController?.setToolbarHidden(true, animated: animated)
        rebuild()
    }

    func rebuild() { tableView.reloadData() }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { sections[section].footer }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.backgroundColor = Theme.surface
        cell.textLabel?.text = row.title
        cell.textLabel?.textColor = row.destructive ? .systemRed : Theme.text
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.textColor = Theme.secondaryText
        switch row.kind {
        case .toggle(let get, let set):
            let toggle = UISwitch()
            toggle.isOn = get()
            toggle.onTintColor = Theme.accent
            toggle.addAction(UIAction { action in set((action.sender as? UISwitch)?.isOn ?? false) }, for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        case .choice(let value, _):
            cell.detailTextLabel?.text = value()
            cell.accessoryType = .disclosureIndicator
        case .action:
            cell.textLabel?.textColor = row.destructive ? .systemRed : Theme.accent
        case .push:
            cell.accessoryType = .disclosureIndicator
        case .info(let value):
            cell.detailTextLabel?.text = value()
            cell.selectionStyle = .none
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = sections[indexPath.section].rows[indexPath.row]
        switch row.kind {
        case .choice(_, let options):
            let sheet = UIAlertController(title: row.title, message: nil, preferredStyle: .actionSheet)
            for (title, pick) in options() {
                sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in pick(); self?.rebuild() })
            }
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            if let pop = sheet.popoverPresentationController, let cell = tableView.cellForRow(at: indexPath) {
                pop.sourceView = cell
                pop.sourceRect = cell.bounds
            }
            present(sheet, animated: true)
        case .action(let run):
            run()
            rebuild()
        case .push(let make):
            navigationController?.pushViewController(make(), animated: true)
        default:
            break
        }
    }
}

// MARK: - Main settings

final class SettingsViewController: SettingsTableViewController {

    var onOpenFavorite: ((URL) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
    }

    override func rebuild() {
        let s = Settings.shared
        let blockingChanged = { ContentBlocker.shared.rebuild() }

        sections = [
            SettingsSection(title: "Ad & tracker blocking", footer: s.blocklistLevel.detail + ". Applies to everything loaded inside Undirect, like a Pi-hole for this browser.", rows: [
                SettingsRow(title: "Domain blocklist", kind: .choice(value: { s.blocklistLevel.title }, options: {
                    BlocklistLevel.allCases.map { level -> (String, () -> Void) in (level.title, { s.blocklistLevel = level; blockingChanged() }) }
                })),
                SettingsRow(title: "Hide common ad slots", kind: .toggle(get: { s.cosmeticFiltering }, set: { s.cosmeticFiltering = $0; blockingChanged() })),
                SettingsRow(title: "Remove link tracking", kind: .toggle(get: { s.stripTrackers }, set: { s.stripTrackers = $0 })),
                SettingsRow(title: "Click through redirect layers", kind: .toggle(get: { s.clickThrough }, set: { s.clickThrough = $0 })),
                SettingsRow(title: "Sites with blocking paused", kind: .push({
                    DomainListViewController(title: "Blocking Paused", store: ContentBlocker.shared.paused,
                                             footer: "Ads and trackers are allowed on these sites.")
                })),
                SettingsRow(title: "Hidden elements", kind: .push({ HiddenElementsViewController() }))
            ]),
            SettingsSection(title: "Cookies", footer: "Cookie-consent pop-ups are rejected and hidden automatically — turn that off above to see them and choose yourself. Sites where you enter a password are remembered automatically so you stay logged in. Everything else is cleared.", rows: [
                SettingsRow(title: "Auto-dismiss cookie banners", kind: .toggle(get: { s.autoHandleCookieBanners }, set: { s.autoHandleCookieBanners = $0 })),
                SettingsRow(title: "Block third-party cookies", kind: .toggle(get: { s.blockThirdPartyCookies }, set: { s.blockThirdPartyCookies = $0; blockingChanged() })),
                SettingsRow(title: "Spoof analytics cookies", kind: .toggle(get: { s.spoofAnalyticsCookies }, set: { s.spoofAnalyticsCookies = $0 })),
                SettingsRow(title: "Clear other site data", kind: .choice(value: { s.cookieCleanup.title }, options: {
                    CookieCleanupMode.allCases.map { mode -> (String, () -> Void) in (mode.title, { s.cookieCleanup = mode }) }
                })),
                SettingsRow(title: "Kept logins", kind: .push({
                    DomainListViewController(title: "Kept Logins", store: CookieGuard.shared.keptLogins,
                                             footer: "Cookies for these sites are never cleared. Remove a site to log out of it at the next cleanup.")
                })),
                SettingsRow(title: "Clear all website data now", kind: .action({ [weak self] in
                    CookieGuard.shared.clearEverything { self?.toast("Website data cleared") }
                }), destructive: true)
            ]),
            SettingsSection(title: "Tor", footer: "Tor tabs route through a Tor client built into the app — no VPN. They keep nothing on disk and never share cookies with normal tabs. This is not a hardened Tor Browser; don't rely on it where your safety depends on anonymity.", rows: [
                SettingsRow(title: "Open new tabs with Tor", kind: .toggle(get: { s.torForNewTabs }, set: { s.torForNewTabs = $0 })),
                SettingsRow(title: "Status", kind: .info({ TorManager.shared.state.description }))
            ]),
            SettingsSection(title: "General", footer: nil, rows: [
                SettingsRow(title: "Theme", kind: .choice(value: { s.appTheme.title }, options: {
                    AppTheme.allCases.map { theme -> (String, () -> Void) in (theme.title, { s.appTheme = theme }) }
                })),
                SettingsRow(title: "Preload favorites on Wi-Fi", kind: .toggle(get: { s.preloadFavorites }, set: { s.preloadFavorites = $0 })),
                SettingsRow(title: "Tab bar side", kind: .choice(value: { s.sidebarPosition.title }, options: {
                    SidebarPosition.allCases.map { pos -> (String, () -> Void) in (pos.title, { s.sidebarPosition = pos }) }
                })),
                SettingsRow(title: "New tab page layout", kind: .push({ NTPLayoutViewController() })),
                SettingsRow(title: "Favorites", kind: .push({ [weak self] in
                    let vc = FavoritesViewController()
                    vc.onOpen = self?.onOpenFavorite
                    return vc
                })),
                SettingsRow(title: "Trusted sites (redirects & pop-ups)", kind: .push({ WhitelistViewController() })),
                SettingsRow(title: "Reset blocking statistics", kind: .action({ BlockStats.shared.reset() }), destructive: true)
            ])
        ]
        super.rebuild()
    }

    private func toast(_ text: String) {
        let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        present(alert, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { alert.dismiss(animated: true) }
    }
}

// MARK: - New tab page layout

final class NTPLayoutViewController: UITableViewController {

    private var order: [NTPSection] = Settings.shared.ntpOrder

    init() { super.init(style: Theme.tableViewStyle) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "New Tab Page"
        tableView.backgroundColor = Theme.background
        tableView.isEditing = true
        tableView.allowsSelectionDuringEditing = false
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        ["Sections (drag to reorder)", "Favorites grid", "Statistics"][section]
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        [order.count, 2, 1][section]
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.backgroundColor = Theme.surface
        cell.textLabel?.textColor = Theme.text
        let s = Settings.shared

        switch (indexPath.section, indexPath.row) {
        case (0, let row):
            let section = order[row]
            cell.textLabel?.text = section.title
            cell.editingAccessoryView = makeSwitch(on: !s.ntpHidden.contains(section)) { on in
                var hidden = s.ntpHidden
                if on { hidden.remove(section) } else { hidden.insert(section) }
                s.ntpHidden = hidden
            }
        case (1, 0):
            cell.textLabel?.text = "Columns: \(s.ntpColumns)"
            let stepper = UIStepper()
            stepper.minimumValue = 3
            stepper.maximumValue = 6
            stepper.value = Double(s.ntpColumns)
            stepper.addAction(UIAction { [weak cell] action in
                let v = Int((action.sender as? UIStepper)?.value ?? 4)
                s.ntpColumns = v
                cell?.textLabel?.text = "Columns: \(v)"
            }, for: .valueChanged)
            cell.editingAccessoryView = stepper
        case (1, _):
            cell.textLabel?.text = "Show titles"
            cell.editingAccessoryView = makeSwitch(on: s.ntpShowTitles) { s.ntpShowTitles = $0 }
        default:
            cell.textLabel?.text = "Detailed breakdown"
            cell.editingAccessoryView = makeSwitch(on: s.ntpDetailedStats) { s.ntpDetailedStats = $0 }
        }
        return cell
    }

    private func makeSwitch(on: Bool, changed: @escaping (Bool) -> Void) -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = on
        toggle.onTintColor = Theme.accent
        toggle.addAction(UIAction { action in changed((action.sender as? UISwitch)?.isOn ?? false) }, for: .valueChanged)
        return toggle
    }

    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle { .none }
    override func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool { false }
    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { indexPath.section == 0 }

    override func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt source: IndexPath,
                            toProposedIndexPath proposed: IndexPath) -> IndexPath {
        if proposed.section == 0 { return proposed }
        return IndexPath(row: order.count - 1, section: 0)
    }

    override func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        let item = order.remove(at: source.row)
        order.insert(item, at: destination.row)
        Settings.shared.ntpOrder = order
    }
}

// MARK: - Domain list

final class DomainListViewController: UITableViewController {
    private let store: DomainSetStore
    private let footer: String
    private var domains: [String] = []

    init(title: String, store: DomainSetStore, footer: String) {
        self.store = store
        self.footer = footer
        super.init(style: Theme.tableViewStyle)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = Theme.background
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(add))
        reload()
    }

    private func reload() {
        domains = store.all()
        tableView.reloadData()
    }

    @objc private func add() {
        let alert = UIAlertController(title: "Add site", message: nil, preferredStyle: .alert)
        alert.addTextField { f in
            f.placeholder = "example.com"
            f.keyboardType = .URL
            f.autocapitalizationType = .none
            f.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self] _ in
            guard let text = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            let host = URL(string: text.contains("://") ? text : "https://" + text)?.host ?? text
            self?.store.add(host: host)
            self?.reload()
        })
        present(alert, animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(domains.count, 1) }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { footer }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = Theme.surface
        cell.selectionStyle = .none
        if domains.isEmpty {
            cell.textLabel?.text = "None yet"
            cell.textLabel?.textColor = Theme.secondaryText
        } else {
            cell.textLabel?.text = domains[indexPath.row]
            cell.textLabel?.textColor = Theme.text
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { !domains.isEmpty }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, domains.indices.contains(indexPath.row) else { return }
        store.remove(host: domains[indexPath.row])
        reload()
    }
}

// MARK: - Hidden elements

final class HiddenElementsViewController: UITableViewController {
    private var entries: [(String, [String])] = []

    init() { super.init(style: Theme.tableViewStyle) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Hidden Elements"
        tableView.backgroundColor = Theme.background
        reload()
    }

    private func reload() {
        entries = ElementHideStore.shared.all().sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(entries.count, 1) }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Use “Hide element…” in the page menu to add rules. Swipe to remove a site's rules."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.backgroundColor = Theme.surface
        cell.selectionStyle = .none
        if entries.isEmpty {
            cell.textLabel?.text = "None yet"
            cell.textLabel?.textColor = Theme.secondaryText
        } else {
            cell.textLabel?.text = entries[indexPath.row].0
            cell.textLabel?.textColor = Theme.text
            cell.detailTextLabel?.text = "\(entries[indexPath.row].1.count)"
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { !entries.isEmpty }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, entries.indices.contains(indexPath.row) else { return }
        ElementHideStore.shared.removeAll(for: entries[indexPath.row].0)
        reload()
    }
}
