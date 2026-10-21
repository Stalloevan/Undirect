import UIKit

/// Add and remove domains from ad & tracker blocking:
///  - "Blocked by you": extra domains to block.
///  - "Allowed by you": domains to let through even if a built-in list blocks them.
final class CustomBlocklistViewController: UITableViewController {

    private enum Section: Int { case blocked, allowed }

    private var blocked: [String] = []
    private var allowed: [String] = []

    init() { super.init(style: Theme.tableViewStyle) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Custom Blocklist"
        tableView.backgroundColor = Theme.background
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            menu: UIMenu(children: [
                UIAction(title: "Block a domain…", image: UIImage(systemName: "nosign")) { [weak self] _ in self?.prompt(blocking: true) },
                UIAction(title: "Allow a domain…", image: UIImage(systemName: "checkmark.shield")) { [weak self] _ in self?.prompt(blocking: false) }
            ]))
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: UserBlocklist.didChange, object: nil)
        reload()
    }

    @objc private func reload() {
        blocked = UserBlocklist.shared.blocked
        allowed = UserBlocklist.shared.allowed
        tableView.reloadData()
    }

    private func prompt(blocking: Bool) {
        let alert = UIAlertController(
            title: blocking ? "Block a domain" : "Allow a domain",
            message: blocking
                ? "Requests to this domain and all its subdomains are blocked in every tab."
                : "Lets this domain through even if a built-in list blocks it. This also unblocks the list entry that covers it.",
            preferredStyle: .alert)
        alert.addTextField { f in
            f.placeholder = "example.com"
            f.keyboardType = .URL
            f.autocapitalizationType = .none
            f.autocorrectionType = .no
            f.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: blocking ? "Block" : "Allow", style: .default) { [weak self] _ in
            let text = alert.textFields?.first?.text ?? ""
            let outcome = blocking ? UserBlocklist.shared.block(text) : UserBlocklist.shared.allow(text)
            switch outcome {
            case .added: break
            case .alreadyThere(let host): self?.notice("\(host) is already on this list.")
            case .invalid: self?.notice("That doesn't look like a domain. Try something like example.com.")
            }
        })
        present(alert, animated: true)
    }

    private func notice(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: Table

    private func entries(in section: Int) -> [String] { section == Section.blocked.rawValue ? blocked : allowed }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(entries(in: section).count, 1)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == Section.blocked.rawValue ? "Blocked by you" : "Allowed by you"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == Section.blocked.rawValue
            ? "Added on top of the built-in lists, and applied even when the blocklist is Off. Subdomains are included. Swipe to remove."
            : "Domains the built-in lists block that you want to load anyway. Swipe to remove."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = Theme.surface
        cell.selectionStyle = .none
        let list = entries(in: indexPath.section)
        if list.isEmpty {
            cell.textLabel?.text = "None yet"
            cell.textLabel?.textColor = Theme.secondaryText
        } else {
            cell.textLabel?.text = list[indexPath.row]
            cell.textLabel?.textColor = Theme.text
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        !entries(in: indexPath.section).isEmpty
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        let list = entries(in: indexPath.section)
        guard list.indices.contains(indexPath.row) else { return }
        if indexPath.section == Section.blocked.rawValue {
            UserBlocklist.shared.removeBlocked(list[indexPath.row])
        } else {
            UserBlocklist.shared.removeAllowed(list[indexPath.row])
        }
    }
}
