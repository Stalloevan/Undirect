import UIKit

class WhitelistViewController: UITableViewController {

    private var domains: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Whitelist"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(addDomain)
        )
        reload()
    }

    private func reload() {
        domains = WhitelistStore.shared.all()
        tableView.reloadData()
    }

    @objc private func addDomain() {
        let alert = UIAlertController(
            title: "Add Domain",
            message: "Redirects and pop-ups will be allowed for this domain and its subdomains.",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "example.com"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self] _ in
            guard let text = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            WhitelistStore.shared.add(host: text)
            self?.reload()
        })
        present(alert, animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        domains.isEmpty ? 1 : domains.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        if domains.isEmpty {
            cell.textLabel?.text = "No whitelisted domains yet"
            cell.textLabel?.textColor = .secondaryLabel
            cell.selectionStyle = .none
        } else {
            cell.textLabel?.text = domains[indexPath.row]
            cell.textLabel?.textColor = .label
            cell.selectionStyle = .none
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        !domains.isEmpty
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, indexPath.row < domains.count else { return }
        let host = domains[indexPath.row]
        WhitelistStore.shared.remove(host: host)
        reload()
    }
}
