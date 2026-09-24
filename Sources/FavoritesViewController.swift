import UIKit

class FavoritesViewController: UITableViewController {

    private var favorites: [FavoriteSite] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Favorites"
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
        reload() // pick up favorites toggled while browsing
    }

    private func reload() {
        favorites = FavoritesStore.shared.all()
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        favorites.isEmpty ? 1 : favorites.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        if favorites.isEmpty {
            cell.textLabel?.text = "No favorites yet"
            cell.textLabel?.textColor = .secondaryLabel
            cell.accessoryType = .none
            cell.selectionStyle = .none
        } else {
            let favorite = favorites[indexPath.row]
            cell.textLabel?.text = favorite.title.isEmpty ? favorite.urlString : favorite.title
            cell.textLabel?.textColor = .label
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !favorites.isEmpty, let url = URL(string: favorites[indexPath.row].urlString) else { return }
        // Opening a favorite is just navigation — it does not touch the whitelist.
        navigationController?.pushViewController(BrowserViewController(startURL: url), animated: true)
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        !favorites.isEmpty
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, indexPath.row < favorites.count else { return }
        FavoritesStore.shared.remove(at: indexPath.row)
        reload()
    }
}
