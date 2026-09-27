import UIKit
import AppIntents
import UniformTypeIdentifiers

// Every action here drives the current tab in Undirect, so each one brings
// the app forward and waits for the page to be ready before returning.
// "Element" parameters take either a CSS selector or the element's visible
// text/label ("Sign in", "Search"), whichever is easier.

// MARK: - Recorded automations

struct AutomationEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Browser Automation"
    static var defaultQuery = AutomationEntityQuery()

    var id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ automation: BrowserAutomation) {
        id = automation.id
        name = automation.name
    }
}

struct AutomationEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [AutomationEntity] {
        AutomationStore.shared.all().filter { identifiers.contains($0.id) }.map(AutomationEntity.init)
    }

    func suggestedEntities() async throws -> [AutomationEntity] {
        AutomationStore.shared.all().map(AutomationEntity.init)
    }
}

struct RunAutomationIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Automation in Undirect"
    static var description = IntentDescription("Runs an automation you recorded in Undirect (⋯ › Record Automation) on the current tab. Steps set to use Shortcut input take one line of Input each, in order. Returns the final page's URL.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Automation")
    var automation: AutomationEntity

    @Parameter(title: "Input", description: "One line per step that uses Shortcut input.", default: "")
    var input: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let stored = AutomationStore.shared.find(id: automation.id) else {
            throw AutomationError("That automation no longer exists.")
        }
        let url = try await AutomationRunner.shared.run(stored, input: input)
        return .result(value: url)
    }
}

// MARK: - Navigation

struct GoToURLIntent: AppIntent {
    static var title: LocalizedStringResource = "Go to URL in Current Tab"
    static var description = IntentDescription("Loads a URL in Undirect's current tab and waits until it has finished loading.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "URL")
    var url: URL

    func perform() async throws -> some IntentResult {
        try await AutomationRunner.shared.navigate(to: url)
        return .result()
    }
}

enum BrowserHistoryAction: String, AppEnum, CaseIterable {
    case back, forward, reload
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Page Action"
    static var caseDisplayRepresentations: [BrowserHistoryAction: DisplayRepresentation] = [
        .back: "Go Back", .forward: "Go Forward", .reload: "Reload"
    ]
}

struct PageHistoryIntent: AppIntent {
    static var title: LocalizedStringResource = "Go Back, Forward or Reload in Undirect"
    static var description = IntentDescription("Goes back, forward, or reloads the current tab, then waits for the page to load.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Action", default: .back)
    var action: BrowserHistoryAction

    func perform() async throws -> some IntentResult {
        let mapped: AutomationRunner.HistoryAction
        switch action {
        case .back: mapped = .back
        case .forward: mapped = .forward
        case .reload: mapped = .reload
        }
        try await AutomationRunner.shared.history(mapped)
        return .result()
    }
}

struct WaitForPageIntent: AppIntent {
    static var title: LocalizedStringResource = "Wait for Page to Load in Undirect"
    static var description = IntentDescription("Waits until the current tab has finished loading.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Timeout (seconds)", default: 30)
    var timeout: Int

    func perform() async throws -> some IntentResult {
        try await AutomationRunner.shared.waitForCurrentPage(timeout: TimeInterval(max(1, timeout)))
        return .result()
    }
}

struct WaitForElementIntent: AppIntent {
    static var title: LocalizedStringResource = "Wait for Element in Undirect"
    static var description = IntentDescription("Waits for an element to appear on the current page. Returns whether it appeared before the timeout.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Element", description: "A CSS selector, or the element's visible text or label.")
    var element: String

    @Parameter(title: "Timeout (seconds)", default: 10)
    var timeout: Int

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let found = try await AutomationRunner.shared.waitForElementOnCurrentPage(element, timeout: TimeInterval(max(1, timeout)))
        return .result(value: found)
    }
}

// MARK: - Interaction

struct TapElementIntent: AppIntent {
    static var title: LocalizedStringResource = "Tap Element in Undirect"
    static var description = IntentDescription("Taps a button, link or other element on the current page, then waits for any page load it starts.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Element", description: "A CSS selector, or the element's visible text or label.")
    var element: String

    func perform() async throws -> some IntentResult {
        try await AutomationRunner.shared.tap(element)
        return .result()
    }
}

struct TypeTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Type Text in Undirect"
    static var description = IntentDescription("Fills a text field on the current page.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Field", description: "A CSS selector, or the field's label or placeholder.")
    var field: String

    @Parameter(title: "Press Enter Afterwards", default: false)
    var pressEnter: Bool

    func perform() async throws -> some IntentResult {
        try await AutomationRunner.shared.type(text, into: field, pressEnter: pressEnter)
        return .result()
    }
}

struct SelectOptionIntent: AppIntent {
    static var title: LocalizedStringResource = "Choose Menu Option in Undirect"
    static var description = IntentDescription("Chooses an option in a drop-down menu on the current page.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Option", description: "The option's visible text or value.")
    var option: String

    @Parameter(title: "Menu", description: "A CSS selector, or the menu's label.")
    var menu: String

    func perform() async throws -> some IntentResult {
        try await AutomationRunner.shared.select(option, in: menu)
        return .result()
    }
}

enum ScrollDirection: String, AppEnum, CaseIterable {
    case down, up, top, bottom
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Scroll"
    static var caseDisplayRepresentations: [ScrollDirection: DisplayRepresentation] = [
        .down: "Down one screen", .up: "Up one screen", .top: "To the top", .bottom: "To the bottom"
    ]
}

struct ScrollPageIntent: AppIntent {
    static var title: LocalizedStringResource = "Scroll Page in Undirect"
    static var description = IntentDescription("Scrolls the current page.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Direction", default: .down)
    var direction: ScrollDirection

    func perform() async throws -> some IntentResult {
        try await AutomationRunner.shared.scroll(direction.rawValue)
        return .result()
    }
}

struct RunJavaScriptIntent: AppIntent {
    static var title: LocalizedStringResource = "Run JavaScript in Undirect"
    static var description = IntentDescription("Runs JavaScript on the current page (with access to the page's own variables). Use `return` to send a value back; promises are awaited and objects come back as JSON.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "JavaScript", inputOptions: String.IntentInputOptions(multiline: true))
    var code: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await AutomationRunner.shared.javascript(code)
        return .result(value: result)
    }
}

// MARK: - Reading the page

enum PageDetailKind: String, AppEnum, CaseIterable {
    case url, title, text, html, selection
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Page Detail"
    static var caseDisplayRepresentations: [PageDetailKind: DisplayRepresentation] = [
        .url: "URL", .title: "Title", .text: "Visible Text", .html: "HTML", .selection: "Selected Text"
    ]
}

struct GetPageDetailIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Page Details from Undirect"
    static var description = IntentDescription("Returns the current page's URL, title, visible text, HTML or selected text.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Detail", default: .url)
    var detail: PageDetailKind

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let mapped: AutomationRunner.PageDetail
        switch detail {
        case .url: mapped = .url
        case .title: mapped = .title
        case .text: mapped = .text
        case .html: mapped = .html
        case .selection: mapped = .selection
        }
        return .result(value: try await AutomationRunner.shared.pageDetail(mapped))
    }
}

struct GetElementsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Elements from Undirect"
    static var description = IntentDescription("Returns something from every element matching a CSS selector (or the one element with that text): its text, link, image source, value, HTML, or any attribute.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Elements", description: "A CSS selector like `a.result`, or an element's visible text.")
    var elements: String

    @Parameter(title: "Get", description: "text, href, src, value, html, or any attribute name.", default: "text")
    var attribute: String

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let attr = attribute.trimmingCharacters(in: .whitespaces).lowercased()
        let values = try await AutomationRunner.shared.elements(elements, attribute: attr.isEmpty ? "text" : attr)
        return .result(value: values)
    }
}

struct ScreenshotPageIntent: AppIntent {
    static var title: LocalizedStringResource = "Screenshot Page in Undirect"
    static var description = IntentDescription("Returns an image of the current tab's visible page.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let data = try await AutomationRunner.shared.screenshot()
        return .result(value: IntentFile(data: data, filename: "Undirect Screenshot.png", type: .png))
    }
}

// MARK: - Tabs

struct GetOpenTabsIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Open Tabs from Undirect"
    static var description = IntentDescription("Returns the URLs of all open tabs, in order.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        return .result(value: try await AutomationRunner.shared.tabURLs())
    }
}

struct SwitchTabIntent: AppIntent {
    static var title: LocalizedStringResource = "Switch Tab in Undirect"
    static var description = IntentDescription("Switches to an open tab by its position (1 is the first tab).")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Tab Number", default: 1)
    var number: Int

    func perform() async throws -> some IntentResult {
        try await AutomationRunner.shared.selectTab(number: number)
        return .result()
    }
}

struct CloseTabIntent: AppIntent {
    static var title: LocalizedStringResource = "Close Current Tab in Undirect"
    static var description = IntentDescription("Closes the tab that's currently showing.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        try await AutomationRunner.shared.closeCurrentTab()
        return .result()
    }
}
