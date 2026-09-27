import UIKit

/// Settings › Automations: everything you've recorded.
final class AutomationListViewController: UITableViewController {

    /// Set by the browser so "Run" can close settings and show the page.
    var onRun: ((BrowserAutomation) -> Void)?

    private var items: [BrowserAutomation] { AutomationStore.shared.all() }

    init() { super.init(style: Theme.tableViewStyle) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Automations"
        tableView.backgroundColor = Theme.background
        if onRun == nil {
            onRun = { AutomationHost.browser?.runAutomationFromApp($0) }
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addBlank))
        NotificationCenter.default.addObserver(tableView!, selector: #selector(UITableView.reloadData),
                                               name: AutomationStore.didChange, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(items.count, 1) }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "To record one, open a page and choose ⋯ › Record Automation, then do the steps yourself. In the Shortcuts app, use “Run Automation in Undirect”. There are also individual actions (Tap Element, Type Text, Get Page Details, Run JavaScript, Screenshot…) for building a shortcut by hand."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Theme.surface
        guard !items.isEmpty else {
            cell.textLabel?.text = "No automations yet"
            cell.textLabel?.textColor = Theme.secondaryText
            cell.selectionStyle = .none
            return cell
        }
        let item = items[indexPath.row]
        cell.textLabel?.text = item.name
        cell.textLabel?.textColor = Theme.text
        let inputs = item.steps.filter(\.usesInput).count
        cell.detailTextLabel?.text = "\(item.steps.count) step\(item.steps.count == 1 ? "" : "s")"
            + (inputs > 0 ? " · \(inputs) input\(inputs == 1 ? "" : "s")" : "")
        cell.detailTextLabel?.textColor = Theme.secondaryText
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard items.indices.contains(indexPath.row) else { return }
        let editor = AutomationEditorViewController(automation: items[indexPath.row])
        editor.onRun = onRun
        navigationController?.pushViewController(editor, animated: true)
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { !items.isEmpty }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, items.indices.contains(indexPath.row) else { return }
        AutomationStore.shared.remove(id: items[indexPath.row].id)
    }

    @objc private func addBlank() {
        let alert = UIAlertController(title: "New Automation",
                                      message: "Recording is usually easiest (⋯ › Record Automation on any page). Or start empty and add steps by hand.",
                                      preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Name" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            let automation = BrowserAutomation(name: name.isEmpty ? "Automation" : name, steps: [])
            AutomationStore.shared.upsert(automation)
            let editor = AutomationEditorViewController(automation: automation)
            editor.onRun = self?.onRun
            self?.navigationController?.pushViewController(editor, animated: true)
        })
        present(alert, animated: true)
    }
}

/// Edit one automation's steps: reorder, delete, change values/elements,
/// switch a step to take Shortcut input, add new steps, rename, test-run.
final class AutomationEditorViewController: UITableViewController {

    private var automation: BrowserAutomation
    var onRun: ((BrowserAutomation) -> Void)?

    init(automation: BrowserAutomation) {
        self.automation = automation
        super.init(style: Theme.tableViewStyle)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = automation.name
        tableView.backgroundColor = Theme.background
        let add = UIBarButtonItem(systemItem: .add, menu: addMenu())
        let more = UIBarButtonItem(image: Theme.icon("ellipsis.circle"), menu: moreMenu())
        navigationItem.rightBarButtonItems = [more, add, editButtonItem]
    }

    private func save() {
        AutomationStore.shared.upsert(automation)
        title = automation.name
        tableView.reloadData()
    }

    // MARK: Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(automation.steps.count, 1) }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Runs on whichever tab is showing. Tap a step to edit it; steps using Shortcut input take one line of the Run Automation action's Input each, in order. Elements are found by their recorded selector, or by their text if the site has changed."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Theme.surface
        guard !automation.steps.isEmpty else {
            cell.textLabel?.text = "No steps — tap + to add one"
            cell.textLabel?.textColor = Theme.secondaryText
            cell.selectionStyle = .none
            return cell
        }
        let step = automation.steps[indexPath.row]
        cell.textLabel?.text = "\(indexPath.row + 1). \(step.summary)"
        cell.textLabel?.numberOfLines = 2
        cell.textLabel?.textColor = Theme.text
        if step.kind.needsElement, let selector = step.selector, !selector.isEmpty {
            cell.detailTextLabel?.text = selector
            cell.detailTextLabel?.textColor = Theme.secondaryText
            cell.detailTextLabel?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        }
        if step.usesInput {
            cell.accessoryView = {
                let badge = UILabel()
                badge.text = " INPUT "
                badge.font = .systemFont(ofSize: 10, weight: .bold)
                badge.textColor = .white
                badge.backgroundColor = Theme.accent
                badge.layer.cornerRadius = 4
                badge.clipsToBounds = true
                badge.sizeToFit()
                return badge
            }()
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { !automation.steps.isEmpty }
    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { automation.steps.count > 1 }

    override func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        let step = automation.steps.remove(at: source.row)
        automation.steps.insert(step, at: destination.row)
        save()
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, automation.steps.indices.contains(indexPath.row) else { return }
        automation.steps.remove(at: indexPath.row)
        save()
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard automation.steps.indices.contains(indexPath.row) else { return }
        editStep(at: indexPath.row, from: tableView.cellForRow(at: indexPath))
    }

    // MARK: Editing a step

    private func editStep(at index: Int, from cell: UITableViewCell?) {
        let step = automation.steps[index]
        let sheet = UIAlertController(title: step.kind.title, message: step.summary, preferredStyle: .actionSheet)
        if step.kind.needsValue && !step.usesInput {
            sheet.addAction(UIAlertAction(title: "Edit \(step.kind == .wait ? "Seconds" : step.kind == .javascript ? "Code" : "Value")…", style: .default) { [weak self] _ in
                self?.prompt(title: step.kind.valuePrompt, text: step.value, multiline: step.kind == .javascript) { value in
                    self?.automation.steps[index].value = value
                    self?.save()
                }
            })
        }
        if step.kind.needsElement {
            sheet.addAction(UIAlertAction(title: "Edit Element…", style: .default) { [weak self] _ in
                self?.editElement(at: index)
            })
        }
        if step.kind.canUseInput {
            sheet.addAction(UIAlertAction(title: step.usesInput ? "Use a Fixed Value Instead" : "Use Shortcut Input", style: .default) { [weak self] _ in
                guard let self else { return }
                self.automation.steps[index].usesInput.toggle()
                if !self.automation.steps[index].usesInput, (self.automation.steps[index].value ?? "").isEmpty {
                    self.prompt(title: step.kind.valuePrompt, text: nil, multiline: false) { value in
                        self.automation.steps[index].value = value
                        self.save()
                    }
                }
                self.save()
            })
        }
        sheet.addAction(UIAlertAction(title: "Duplicate", style: .default) { [weak self] _ in
            var copy = step
            copy.id = UUID()
            self?.automation.steps.insert(copy, at: index + 1)
            self?.save()
        })
        sheet.addAction(UIAlertAction(title: "Delete Step", style: .destructive) { [weak self] _ in
            self?.automation.steps.remove(at: index)
            self?.save()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let pop = sheet.popoverPresentationController, let cell {
            pop.sourceView = cell
            pop.sourceRect = cell.bounds
        }
        present(sheet, animated: true)
    }

    private func editElement(at index: Int) {
        let step = automation.steps[index]
        let alert = UIAlertController(title: "Element",
                                      message: "Its visible text or label is enough — the CSS selector is optional and tried first.",
                                      preferredStyle: .alert)
        alert.addTextField { f in
            f.placeholder = "Text or label, e.g. Sign in"
            f.text = step.label
        }
        alert.addTextField { f in
            f.placeholder = "CSS selector (optional)"
            f.text = step.selector
            f.autocapitalizationType = .none
            f.autocorrectionType = .no
            f.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            let label = alert?.textFields?[0].text?.trimmingCharacters(in: .whitespaces) ?? ""
            let selector = alert?.textFields?[1].text?.trimmingCharacters(in: .whitespaces) ?? ""
            self?.automation.steps[index].label = label.isEmpty ? nil : label
            self?.automation.steps[index].selector = selector.isEmpty ? nil : selector
            self?.save()
        })
        present(alert, animated: true)
    }

    private func prompt(title: String, text: String?, multiline: Bool, done: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: multiline ? "Tip: use return to pass a value on." : nil, preferredStyle: .alert)
        alert.addTextField { f in
            f.text = text
            f.autocapitalizationType = .none
            f.autocorrectionType = .no
            if multiline { f.font = .monospacedSystemFont(ofSize: 13, weight: .regular) }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak alert] _ in
            done(alert?.textFields?.first?.text ?? "")
        })
        present(alert, animated: true)
    }

    // MARK: Menus

    private func addMenu() -> UIMenu {
        UIMenu(children: AutomationStep.Kind.allCases.map { kind in
            UIAction(title: kind.title) { [weak self] _ in self?.addStep(kind) }
        })
    }

    private func addStep(_ kind: AutomationStep.Kind) {
        let append: (AutomationStep) -> Void = { [weak self] step in
            self?.automation.steps.append(step)
            self?.save()
        }
        switch kind {
        case .back:
            append(AutomationStep(kind: .back))
        case .pressEnter, .tap, .waitFor:
            let alert = UIAlertController(title: kind.title, message: "The element's visible text or label, or a CSS selector.", preferredStyle: .alert)
            alert.addTextField { $0.placeholder = "e.g. Sign in" }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak alert] _ in
                let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
                guard !text.isEmpty else { return }
                append(AutomationStep(kind: kind, selector: text, label: text))
            })
            present(alert, animated: true)
        case .type, .select:
            let alert = UIAlertController(title: kind.title, message: "Leave the value empty to take it from the Shortcut's Input.", preferredStyle: .alert)
            alert.addTextField { $0.placeholder = kind == .type ? "Field label, e.g. Search" : "Menu label" }
            alert.addTextField { $0.placeholder = kind.valuePrompt }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak alert] _ in
                let target = alert?.textFields?[0].text?.trimmingCharacters(in: .whitespaces) ?? ""
                let value = alert?.textFields?[1].text ?? ""
                guard !target.isEmpty else { return }
                append(AutomationStep(kind: kind, selector: target, label: target,
                                      value: value.isEmpty ? nil : value, usesInput: value.isEmpty))
            })
            present(alert, animated: true)
        default:
            prompt(title: kind.valuePrompt, text: kind == .wait ? "2" : kind == .scroll ? "down" : nil,
                   multiline: kind == .javascript) { value in
                append(AutomationStep(kind: kind, value: value))
            }
        }
    }

    private func moreMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Run Now", image: Theme.icon("play.fill")) { [weak self] _ in
                guard let self else { return }
                self.onRun?(self.automation)
            },
            UIAction(title: "Rename", image: Theme.icon("pencil")) { [weak self] _ in
                guard let self else { return }
                self.prompt(title: "Name", text: self.automation.name, multiline: false) { name in
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    self.automation.name = trimmed
                    self.save()
                }
            },
            UIAction(title: "Delete Automation", image: Theme.icon("trash"), attributes: .destructive) { [weak self] _ in
                guard let self else { return }
                AutomationStore.shared.remove(id: self.automation.id)
                self.navigationController?.popViewController(animated: true)
            }
        ])
    }
}
