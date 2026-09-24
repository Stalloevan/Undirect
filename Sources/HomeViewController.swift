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
        label.text = "Undirect loads the page in a protected view. Any site NOT on your whitelist will have automatic redirects and pop-up / new-tab attempts blocked. The domain you enter is trusted automatically for that visit; add more domains from the whitelist screen."
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Undirect"
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Whitelist",
            style: .plain,
            target: self,
            action: #selector(openWhitelist)
        )

        urlField.delegate = self
        goButton.addTarget(self, action: #selector(openURL), for: .touchUpInside)

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
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    @objc private func openWhitelist() {
        navigationController?.pushViewController(WhitelistViewController(), animated: true)
    }

    @objc private func openURL() {
        guard var text = urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        if !text.contains("://") {
            text = "https://" + text
        }
        guard let url = URL(string: text), let host = url.host else {
            presentAlert(message: "That doesn't look like a valid URL.")
            return
        }
        // Trust the entry domain for this session so the site you explicitly asked for loads normally.
        WhitelistStore.shared.add(host: host)

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
