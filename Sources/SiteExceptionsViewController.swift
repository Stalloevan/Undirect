import UIKit

/// One list for every per-site exception: sites trusted to redirect/open
/// pop-ups, and sites with ad & tracker blocking paused. Each site can have
/// either or both; the two are still stored separately underneath, since
/// they control unrelated things.
final class SiteExceptionsViewController: UITableViewController {

    private struct Entry {
        let host: String
        let trusted: Bool
        let paused: Bool
    }

    private var entries: [Entry] = []

    init() { super.init(style: Theme.tableViewStyle) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Site Exceptions"
        tableView.backgroundColor = Theme.background
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addSite))
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(reload), name: WhitelistStore.didChange, object: nil)
        nc.addObserver(self, selector: #selector(reload), name: DomainSetStore.didChange, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        reload()
    }

    @objc private func reload() {
        let trusted = Set(WhitelistStore.shared.all())
        let paused = Set(ContentBlocker.shared.paused.all())
        entries = trusted.union(paused).sorted().map {
            Entry(host: $0, trusted: trusted.contains($0), paused: paused.contains($0))
        }
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(entries.count, 1) }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Each entry also covers its subdomains. Tap a site to change what's allowed, swipe to remove it. You can also add sites from a tab's long-press menu."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Theme.surface
        guard !entries.isEmpty else {
            cell.textLabel?.text = "No exceptions — tap + to add a site"
            cell.textLabel?.textColor = Theme.secondaryText
            cell.selectionStyle = .none
            return cell
        }
        let entry = entries[indexPath.row]
        cell.textLabel?.text = entry.host
        cell.textLabel?.textColor = Theme.text
        cell.detailTextLabel?.text = Self.summary(trusted: entry.trusted, paused: entry.paused)
        cell.detailTextLabel?.textColor = Theme.secondaryText
        cell.imageView?.image = FaviconStore.shared.cached(host: entry.host) ?? FaviconStore.monogram(for: entry.host, tor: false)
        cell.imageView?.layer.cornerRadius = Theme.smallCornerRadius
        cell.imageView?.clipsToBounds = true
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    static func summary(trusted: Bool, paused: Bool) -> String {
        var parts: [String] = []
        if trusted { parts.append("Redirects & pop-ups allowed") }
        if paused { parts.append("Ad blocking paused") }
        return parts.isEmpty ? "No exceptions" : parts.joined(separator: " · ")
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard entries.indices.contains(indexPath.row) else { addSite(); return }
        navigationController?.pushViewController(SiteExceptionEditorViewController(host: entries[indexPath.row].host), animated: true)
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { !entries.isEmpty }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, entries.indices.contains(indexPath.row) else { return }
        let host = entries[indexPath.row].host
        WhitelistStore.shared.remove(host: host)
        ContentBlocker.shared.paused.remove(host: host)
    }

    @objc private func addSite() {
        let alert = UIAlertController(title: "Add a site", message: "Enter a domain like example.com, or paste a link.", preferredStyle: .alert)
        alert.addTextField { f in
            f.placeholder = "example.com"
            f.keyboardType = .URL
            f.autocapitalizationType = .none
            f.autocorrectionType = .no
            f.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Next", style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  let host = URL(string: text.contains("://") ? text : "https://" + text)?.host,
                  host.contains(".") else { return }
            let editor = SiteExceptionEditorViewController(host: DomainUtil.normalize(host))
            self?.navigationController?.pushViewController(editor, animated: true)
        })
        present(alert, animated: true)
    }
}

/// Two switches for one site. Changes apply immediately; a site with both
/// switches off simply isn't an exception any more.
final class SiteExceptionEditorViewController: UITableViewController {

    private let host: String

    init(host: String) {
        self.host = host
        super.init(style: Theme.tableViewStyle)
        title = host
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = Theme.background
    }

    private var isTrusted: Bool { WhitelistStore.shared.isWhitelisted(host: host) }
    private var isPaused: Bool { ContentBlocker.shared.paused.contains(host: host) }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0:
            return "Lets \(host) send you to other sites on its own and open pop-ups and new tabs. Normally both are blocked."
        case 1:
            return "Allows ads and trackers on \(host). Reload the site's open tabs for this to take effect."
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = Theme.surface
        cell.textLabel?.textColor = Theme.text
        cell.textLabel?.numberOfLines = 0
        switch indexPath.section {
        case 0:
            cell.textLabel?.text = "Allow redirects & pop-ups"
            cell.accessoryView = makeSwitch(on: isTrusted) { [host] on in
                if on { WhitelistStore.shared.add(host: host) } else { WhitelistStore.shared.remove(host: host) }
            }
            cell.selectionStyle = .none
        case 1:
            cell.textLabel?.text = "Pause ad & tracker blocking"
            cell.accessoryView = makeSwitch(on: isPaused) { [host] on in
                if on { ContentBlocker.shared.paused.addExact(host: host) } else { ContentBlocker.shared.paused.remove(host: host) }
            }
            cell.selectionStyle = .none
        default:
            cell.textLabel?.text = "Remove All Exceptions for This Site"
            cell.textLabel?.textColor = .systemRed
            cell.textLabel?.textAlignment = .center
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 2 else { return }
        WhitelistStore.shared.remove(host: host)
        ContentBlocker.shared.paused.remove(host: host)
        navigationController?.popViewController(animated: true)
    }

    private func makeSwitch(on: Bool, changed: @escaping (Bool) -> Void) -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = on
        toggle.onTintColor = Theme.accent
        toggle.addAction(UIAction { action in changed((action.sender as? UISwitch)?.isOn ?? false) }, for: .valueChanged)
        return toggle
    }
}
