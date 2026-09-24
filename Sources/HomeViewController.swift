import UIKit

class HomeViewController: UIViewController {

    private let urlField: UITextField = {
        let field = UITextField()
        field.placeholder = "Paste a URL, e.g. example.com"
        field.borderStyle = .roundedRect
        field.keyboardType = .URL
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .go
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    private let goButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Open Protected"
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let explainerLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.text = "Undirect loads the page in a protected view. Any site NOT on your whitelist will have automatic redirects and pop-up / new-tab attempts blocked. Visiting a site does NOT trust it — only an explicit \"Trust Site\" tap while browsing adds it to the whitelist."
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let favoritesButton = UIBarButtonItem(title: "Favorites", style: .plain, target: nil, action: nil)
    private let whitelistButton = UIBarButtonItem(title: "Whitelist", style: .plain, target: nil, action: nil)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Undirect"
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemBackground

        urlField.delegate = self
        goButton.addTarget(self, action: #selector(openURL), for: .touchUpInside)

        favoritesButton.target = self
        favoritesButton.action = #selector(openFavorites)
        whitelistButton.target = self
        whitelistButton.action = #selector(openWhitelist)
        toolbarItems = [favoritesButton, .flexibleSpace(), whitelistButton]

        let stack = UIStackView(arrangedSubviews: [urlField, goButton, explainerLabel])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24)
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
    }

    @objc private func openFavorites() {
        navigationController?.pushViewController(FavoritesViewController(), animated: true)
    }

    @objc private func openWhitelist() {
        navigationController?.pushViewController(WhitelistViewController(), animated: true)
    }

    @objc private func openURL() {
        guard var text = urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        if !text.contains("://") {
            text = "https://" + text
        }
        guard let url = URL(string: text), url.host != nil else {
            presentAlert(message: "That doesn't look like a valid URL.")
            return
        }
        // Entering a site is just navigation. It must NOT trust the site — the
        // whitelist only grows from an explicit "Trust Site" tap in the browser,
        // never from simply visiting or moving around on a page.
        let browser = BrowserViewController(startURL: url)
        navigationController?.pushViewController(browser, animated: true)
    }

    private func presentAlert(message: String) {
        let alert = UIAlertController(title: "Invalid URL", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

extension HomeViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        openURL()
        return true
    }
}
