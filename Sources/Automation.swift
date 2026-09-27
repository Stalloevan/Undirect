import UIKit
import WebKit

// MARK: - Model

/// One step of a browser automation. Recorded automatically (tap, type,
/// select, Enter, typed addresses) or added in the step editor — nobody
/// has to write JSON.
struct AutomationStep: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case open, tap, type, select, pressEnter, scroll, wait, waitFor, back, javascript

        var title: String {
            switch self {
            case .open: return "Open URL"
            case .tap: return "Tap element"
            case .type: return "Type text"
            case .select: return "Choose option"
            case .pressEnter: return "Press Enter"
            case .scroll: return "Scroll"
            case .wait: return "Wait"
            case .waitFor: return "Wait for element"
            case .back: return "Go back"
            case .javascript: return "Run JavaScript"
            }
        }

        var needsElement: Bool { [.tap, .type, .select, .pressEnter, .waitFor].contains(self) }
        var needsValue: Bool { [.open, .type, .select, .scroll, .wait, .javascript].contains(self) }
        var canUseInput: Bool { [.open, .type, .select].contains(self) }

        var valuePrompt: String {
            switch self {
            case .open: return "URL"
            case .type: return "Text to type"
            case .select: return "Option (its value or visible text)"
            case .scroll: return "down, up, top, bottom — or a number of points"
            case .wait: return "Seconds"
            case .javascript: return "JavaScript (use return to pass a value on)"
            default: return "Value"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    /// CSS selector recorded for the element.
    var selector: String?
    /// The element's visible text/label — also the fallback used to find it
    /// if the selector stops matching after a site update.
    var label: String?
    var value: String?
    /// Take `value` from the Shortcut's Input instead (one line per step).
    var usesInput = false

    var summary: String {
        let target = label.flatMap { $0.isEmpty ? nil : "“\($0)”" } ?? selector ?? "element"
        let val = usesInput ? "Shortcut input" : (value ?? "")
        switch kind {
        case .open: return "Open \(usesInput ? "URL from Shortcut input" : val)"
        case .tap: return "Tap \(target)"
        case .type: return usesInput ? "Type Shortcut input into \(target)" : "Type “\(val)” into \(target)"
        case .select: return "Choose “\(val)” in \(target)"
        case .pressEnter: return "Press Enter in \(target)"
        case .scroll: return "Scroll \(val.isEmpty ? "down" : val)"
        case .wait: return "Wait \(val.isEmpty ? "1" : val) s"
        case .waitFor: return "Wait for \(target)"
        case .back: return "Go back"
        case .javascript:
            let oneLine = val.replacingOccurrences(of: "\n", with: " ")
            return "Run JS: \(oneLine.prefix(60))"
        }
    }
}

struct BrowserAutomation: Codable, Equatable {
    var id = UUID()
    var name: String
    var steps: [AutomationStep]
    var created = Date()
}

final class AutomationStore {
    static let shared = AutomationStore()
    static let didChange = Notification.Name("UndirectAutomationsDidChange")

    private let lock = NSLock()
    private var items: [BrowserAutomation]

    private static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("automations.json")
    }

    private init() {
        items = (try? Data(contentsOf: Self.fileURL))
            .flatMap { try? JSONDecoder().decode([BrowserAutomation].self, from: $0) } ?? []
    }

    func all() -> [BrowserAutomation] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    func find(id: UUID) -> BrowserAutomation? { all().first { $0.id == id } }

    func upsert(_ automation: BrowserAutomation) {
        lock.lock()
        if let i = items.firstIndex(where: { $0.id == automation.id }) { items[i] = automation } else { items.append(automation) }
        lock.unlock()
        save()
    }

    func remove(id: UUID) {
        lock.lock(); items.removeAll { $0.id == id }; lock.unlock()
        save()
    }

    private func save() {
        let snapshot = all()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }
}

// MARK: - Host

/// The live browser, for automation and Shortcuts actions.
enum AutomationHost {
    static weak var browser: BrowserContainerViewController?
}

struct AutomationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Recorder

/// Records what you do on one tab — taps, typing, choosing options, Enter,
/// addresses typed into the address bar — as automation steps.
final class AutomationRecorder: NSObject, WKScriptMessageHandler {
    static let shared = AutomationRecorder()
    static let didChange = Notification.Name("UndirectRecorderDidChange")
    private static let handlerName = "undirectRecorder"

    private(set) weak var tab: Tab?
    private(set) var steps: [AutomationStep] = []
    var isRecording: Bool { tab != nil }

    func start(on tab: Tab) {
        if isRecording { _ = finish() }
        self.tab = tab
        steps = []
        if let url = tab.url, url.scheme?.hasPrefix("http") == true {
            steps.append(AutomationStep(kind: .open, value: url.absoluteString))
        }
        let controller = tab.webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .defaultClient)
        controller.add(self, contentWorld: .defaultClient, name: Self.handlerName)
        // Kept by the tab across navigations and script reinstalls.
        tab.recorderScript = WKUserScript(source: Self.script, injectionTime: .atDocumentEnd,
                                          forMainFrameOnly: true, in: .defaultClient)
        tab.webView.evaluateJavaScript(Self.script, in: nil, in: .defaultClient) { _ in }
        notify()
    }

    /// Stops recording and returns what was captured.
    func finish() -> [AutomationStep] {
        if let tab {
            let controller = tab.webView.configuration.userContentController
            controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .defaultClient)
            tab.recorderScript = nil
            tab.webView.evaluateJavaScript("window.__undirectRecorderOff && window.__undirectRecorderOff(); 0",
                                           in: nil, in: .defaultClient) { _ in }
        }
        tab = nil
        let captured = steps
        steps = []
        notify()
        return captured
    }

    func recordOpen(_ url: URL, in tab: Tab) {
        guard tab === self.tab else { return }
        steps.append(AutomationStep(kind: .open, value: url.absoluteString))
        notify()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let tab, message.webView === tab.webView,
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let selector = body["selector"] as? String
        let label = body["label"] as? String
        let value = body["value"] as? String
        switch type {
        case "tap":
            steps.append(AutomationStep(kind: .tap, selector: selector, label: label))
        case "type":
            let isPassword = (body["password"] as? Bool) ?? false
            // Passwords are never stored: that step takes Shortcut input instead.
            var step = AutomationStep(kind: .type, selector: selector, label: label,
                                      value: isPassword ? nil : value, usesInput: isPassword)
            if let last = steps.last, last.kind == .type, last.selector == selector {
                step.id = last.id
                steps[steps.count - 1] = step
            } else {
                steps.append(step)
            }
        case "select":
            steps.append(AutomationStep(kind: .select, selector: selector, label: label, value: value))
        case "enter":
            steps.append(AutomationStep(kind: .pressEnter, selector: selector, label: label))
        default:
            return
        }
        notify()
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private static let script = #"""
    (function () {
      if (window.__undirectRecorderOn) return;
      window.__undirectRecorderOn = true;
      function post(m) { try { window.webkit.messageHandlers.undirectRecorder.postMessage(m); } catch (e) {} }
      function esc(s) { return (window.CSS && CSS.escape) ? CSS.escape(s) : String(s).replace(/[^a-zA-Z0-9_-]/g, '\\$&'); }
      function unique(sel) { try { return document.querySelectorAll(sel).length === 1; } catch (e) { return false; } }
      function good(n) { return n && n.length < 50 && !/\d{4,}/.test(n) && !/^(css|sc|jsx|emotion|svelte)-/.test(n); }
      function quote(v) { return '"' + String(v).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"'; }
      function selectorFor(el) {
        var tag = el.tagName.toLowerCase();
        if (el.id && good(el.id) && unique('#' + esc(el.id))) return '#' + esc(el.id);
        var attrs = ['name', 'data-testid', 'data-test', 'aria-label', 'placeholder', 'title'];
        for (var i = 0; i < attrs.length; i++) {
          var v = el.getAttribute(attrs[i]);
          if (v && v.length < 80) { var s = tag + '[' + attrs[i] + '=' + quote(v) + ']'; if (unique(s)) return s; }
        }
        if (tag === 'a') {
          var href = el.getAttribute('href');
          if (href && href.length < 200) { var s2 = 'a[href=' + quote(href) + ']'; if (unique(s2)) return s2; }
        }
        var parts = [], e = el;
        for (var d = 0; d < 6 && e && e.nodeType === 1 && e !== document.documentElement; d++) {
          if (e.id && good(e.id)) { parts.unshift('#' + esc(e.id)); break; }
          var p = e.tagName.toLowerCase();
          p += Array.prototype.filter.call(e.classList, good).slice(0, 2).map(function (c) { return '.' + esc(c); }).join('');
          var parent = e.parentElement;
          if (parent) {
            var same = Array.prototype.filter.call(parent.children, function (c) { return c.tagName === e.tagName; });
            if (same.length > 1) p += ':nth-of-type(' + (same.indexOf(e) + 1) + ')';
          }
          parts.unshift(p);
          if (unique(parts.join(' > '))) break;
          e = parent;
        }
        return parts.join(' > ');
      }
      function labelFor(el) {
        var t = el.getAttribute('aria-label') || (el.innerText || '').trim() || el.value ||
                el.getAttribute('placeholder') || el.getAttribute('name') || el.getAttribute('title') || '';
        t = String(t).replace(/\s+/g, ' ').trim();
        return t.length > 60 ? t.slice(0, 57) + '…' : t;
      }
      function isTextEntry(el) {
        if (el.tagName === 'TEXTAREA') return true;
        if (el.tagName !== 'INPUT') return false;
        var ty = (el.type || 'text').toLowerCase();
        return ['text', 'search', 'email', 'url', 'tel', 'password', 'number', 'date', 'time',
                'datetime-local', 'month', 'week'].indexOf(ty) !== -1;
      }
      function onClick(e) {
        if (!e.isTrusted || window.__undirectPicking) return;
        var el = e.target;
        if (!el || el.nodeType !== 1 || isTextEntry(el) || el.isContentEditable || el.tagName === 'SELECT' || el.tagName === 'OPTION') return;
        el = el.closest('a[href], button, input[type=submit], input[type=button], input[type=checkbox], input[type=radio], ' +
                        '[role=button], [role=link], [role=tab], [role=menuitem], [role=checkbox], label, summary, [onclick]') || el;
        post({ type: 'tap', selector: selectorFor(el), label: labelFor(el) });
      }
      function report(el) {
        if (el.tagName === 'SELECT') {
          post({ type: 'select', selector: selectorFor(el), label: labelFor(el), value: el.value });
        } else if (isTextEntry(el)) {
          post({ type: 'type', selector: selectorFor(el),
                 label: el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.getAttribute('name') || 'field',
                 value: el.value, password: (el.type || '').toLowerCase() === 'password' });
        }
      }
      function onChange(e) { if (e.isTrusted && e.target && e.target.nodeType === 1) report(e.target); }
      function onKey(e) {
        if (e.key !== 'Enter' || !e.isTrusted) return;
        var el = e.target;
        if (!el || !isTextEntry(el) || el.tagName === 'TEXTAREA') return;
        report(el); // capture the text before Enter submits it
        post({ type: 'enter', selector: selectorFor(el), label: el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.getAttribute('name') || 'field' });
      }
      document.addEventListener('click', onClick, true);
      document.addEventListener('change', onChange, true);
      document.addEventListener('keydown', onKey, true);
      window.__undirectRecorderOff = function () {
        document.removeEventListener('click', onClick, true);
        document.removeEventListener('change', onChange, true);
        document.removeEventListener('keydown', onKey, true);
        window.__undirectRecorderOn = false;
      };
    })();
    """#
}

// MARK: - Runner

/// Drives the current tab: every Shortcuts automation action and recorded
/// automation goes through here.
@MainActor
final class AutomationRunner {
    static let shared = AutomationRunner()

    /// Finds an element by CSS selector, else by its visible text/label.
    private static let findJS = #"""
    function __find(target) {
      if (!target) return null;
      var el = null;
      try { el = document.querySelector(target); } catch (e) {}
      if (el) return el;
      var want = String(target).replace(/\s+/g, ' ').trim().toLowerCase();
      if (!want) return null;
      var list = document.querySelectorAll('a, button, input, select, textarea, label, summary, [role=button], [role=link], [role=tab], [role=menuitem], [aria-label], [placeholder], [title]');
      var partial = null;
      for (var i = 0; i < list.length; i++) {
        var c = list[i];
        var t = (c.getAttribute('aria-label') || c.innerText || c.value || c.getAttribute('placeholder') ||
                 c.getAttribute('name') || c.getAttribute('title') || '').replace(/\s+/g, ' ').trim().toLowerCase();
        if (!t) continue;
        if (t === want) return c;
        if (!partial && t.indexOf(want) !== -1) partial = c;
      }
      return partial;
    }
    var el = __find(sel) || __find(label);
    """#

    // MARK: Browser access

    func browser() async throws -> BrowserContainerViewController {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let browser = AutomationHost.browser, browser.isReadyForAutomation { return browser }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw AutomationError("Undirect's browser isn't ready yet.")
    }

    func currentTab() async throws -> Tab {
        let browser = try await browser()
        guard let tab = browser.automationTab else { throw AutomationError("There's no open tab.") }
        return tab
    }

    // MARK: JavaScript bridge

    private func call(_ body: String, args: [String: Any] = [:], world: WKContentWorld = .defaultClient,
                      in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            webView.callAsyncJavaScript(body, arguments: args, in: nil, in: world) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    private func elementCall(_ action: String, target: String?, label: String?, extra: [String: Any] = [:],
                             in tab: Tab) async throws -> String {
        var args: [String: Any] = ["sel": target ?? "", "label": label ?? ""]
        for (k, v) in extra { args[k] = v }
        let result = try await call(Self.findJS + "\nif (!el) return 'missing';\n" + action, args: args, in: tab.webView)
        return (result as? String) ?? "ok"
    }

    private func describe(_ target: String?, _ label: String?) -> String {
        [label, target].compactMap { $0 }.first { !$0.isEmpty } ?? "element"
    }

    // MARK: Waiting

    func waitForLoad(_ tab: Tab, timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        try await Task.sleep(nanoseconds: 150_000_000)
        while Date() < deadline {
            if !tab.isWaitingForTor, !tab.webView.isLoading,
               (try? await call("return document.readyState;", in: tab.webView)) as? String == "complete" {
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw AutomationError("The page didn't finish loading within \(Int(timeout)) seconds.")
    }

    @discardableResult
    func waitForElement(_ target: String?, label: String? = nil, in tab: Tab, timeout: TimeInterval = 10) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !tab.isWaitingForTor,
               (try? await call(Self.findJS + "\nreturn !!el;", args: ["sel": target ?? "", "label": label ?? ""], in: tab.webView)) as? Bool == true {
                return true
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    /// After a tap/Enter: if it started a navigation, wait for it to finish.
    private func settle(_ tab: Tab, previousURL: URL?) async throws {
        try await Task.sleep(nanoseconds: 600_000_000)
        if tab.webView.isLoading || tab.webView.url != previousURL {
            try await waitForLoad(tab)
        }
    }

    // MARK: Primitives

    func navigate(to url: URL) async throws {
        let browser = try await browser()
        browser.automationNavigate(to: url)
        guard let tab = browser.automationTab else { return }
        try await waitForLoad(tab, timeout: 45)
    }

    func tap(_ target: String?, label: String? = nil) async throws {
        let tab = try await currentTab()
        guard try await waitForElement(target, label: label, in: tab) else {
            throw AutomationError("Couldn't find \(describe(target, label)) on the page.")
        }
        let before = tab.webView.url
        tab.grantAutomationNavigation()
        _ = try await elementCall("""
            el.scrollIntoView({ block: 'center', inline: 'center' });
            var r = el.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
            var o = { bubbles: true, cancelable: true, clientX: x, clientY: y, view: window };
            ['pointerdown', 'mousedown', 'pointerup', 'mouseup'].forEach(function (t) {
              try { el.dispatchEvent(new ((t.indexOf('pointer') === 0 && window.PointerEvent) ? PointerEvent : MouseEvent)(t, o)); } catch (e) {}
            });
            if (typeof el.focus === 'function') el.focus();
            el.click();
            return 'ok';
            """, target: target, label: label, in: tab)
        try await settle(tab, previousURL: before)
    }

    func type(_ text: String, into target: String?, label: String? = nil, pressEnter: Bool = false) async throws {
        let tab = try await currentTab()
        guard try await waitForElement(target, label: label, in: tab) else {
            throw AutomationError("Couldn't find the field \(describe(target, label)).")
        }
        _ = try await elementCall("""
            el.scrollIntoView({ block: 'center' });
            if (typeof el.focus === 'function') el.focus();
            if (el.isContentEditable) {
              el.innerText = text;
            } else {
              var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
              var d = Object.getOwnPropertyDescriptor(proto, 'value');
              if (d && d.set) d.set.call(el, text); else el.value = text;
            }
            try { el.dispatchEvent(new InputEvent('input', { bubbles: true, data: text, inputType: 'insertText' })); }
            catch (e) { el.dispatchEvent(new Event('input', { bubbles: true })); }
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return 'ok';
            """, target: target, label: label, extra: ["text": text], in: tab)
        if pressEnter { try await self.pressEnter(target, label: label) }
    }

    func select(_ option: String, in target: String?, label: String? = nil) async throws {
        let tab = try await currentTab()
        guard try await waitForElement(target, label: label, in: tab) else {
            throw AutomationError("Couldn't find the menu \(describe(target, label)).")
        }
        let result = try await elementCall("""
            if (el.tagName !== 'SELECT') return 'notselect';
            var want = String(option).trim().toLowerCase(), found = null;
            for (var i = 0; i < el.options.length; i++) {
              var o = el.options[i];
              if (o.value === option || o.text.trim().toLowerCase() === want) { found = o; break; }
            }
            if (!found) return 'nooption';
            el.value = found.value;
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return 'ok';
            """, target: target, label: label, extra: ["option": option], in: tab)
        switch result {
        case "notselect": throw AutomationError("\(describe(target, label)) isn't a drop-down menu.")
        case "nooption": throw AutomationError("No option “\(option)” in \(describe(target, label)).")
        default: break
        }
    }

    func pressEnter(_ target: String?, label: String? = nil) async throws {
        let tab = try await currentTab()
        let before = tab.webView.url
        tab.grantAutomationNavigation()
        _ = try await call(Self.findJS + """

            el = el || document.activeElement;
            if (!el) return 'missing';
            var o = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
            var go = el.dispatchEvent(new KeyboardEvent('keydown', o));
            el.dispatchEvent(new KeyboardEvent('keypress', o));
            el.dispatchEvent(new KeyboardEvent('keyup', o));
            if (go && el.form) { if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit(); }
            return 'ok';
            """, args: ["sel": target ?? "", "label": label ?? ""], in: tab.webView)
        try await settle(tab, previousURL: before)
    }

    func scroll(_ how: String) async throws {
        let tab = try await currentTab()
        _ = try await call("""
            var h = String(how || 'down').toLowerCase().trim(), n = parseFloat(h);
            if (!isNaN(n)) window.scrollBy(0, n);
            else if (h === 'top') window.scrollTo(0, 0);
            else if (h === 'bottom') window.scrollTo(0, document.documentElement.scrollHeight);
            else if (h === 'up') window.scrollBy(0, -window.innerHeight * 0.85);
            else window.scrollBy(0, window.innerHeight * 0.85);
            return 'ok';
            """, args: ["how": how], in: tab.webView)
    }

    /// Runs the person's own JavaScript in the page's world (so page
    /// variables are reachable). Promises are awaited.
    func javascript(_ code: String) async throws -> String {
        let tab = try await currentTab()
        let value = try await call(code + "\n;return null;", world: .page, in: tab.webView)
        return Self.stringify(value)
    }

    static func stringify(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return ""
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let other?:
            if JSONSerialization.isValidJSONObject(other),
               let data = try? JSONSerialization.data(withJSONObject: other, options: [.prettyPrinted]) {
                return String(decoding: data, as: UTF8.self)
            }
            return "\(other)"
        }
    }

    enum PageDetail { case url, title, text, html, selection }

    func pageDetail(_ detail: PageDetail) async throws -> String {
        let tab = try await currentTab()
        switch detail {
        case .url: return tab.webView.url?.absoluteString ?? ""
        case .title: return tab.webView.title ?? ""
        case .text:
            return Self.stringify(try await call("return document.body ? document.body.innerText : '';", in: tab.webView))
        case .html:
            return Self.stringify(try await call("return document.documentElement.outerHTML;", in: tab.webView))
        case .selection:
            return Self.stringify(try await call("return String(window.getSelection());", in: tab.webView))
        }
    }

    func elements(_ target: String, attribute: String) async throws -> [String] {
        let tab = try await currentTab()
        let json = try await call(Self.findJS + """

            var list;
            try { list = Array.prototype.slice.call(document.querySelectorAll(sel)); } catch (e) { list = el ? [el] : []; }
            if (!list.length && el) list = [el];
            var out = [];
            for (var i = 0; i < list.length; i++) {
              var n = list[i], v = null;
              if (attr === 'text') v = (n.innerText || n.textContent || '').trim();
              else if (attr === 'html') v = n.outerHTML;
              else if (attr === 'value') v = n.value;
              else if (attr === 'href' && n.href) v = String(n.href);
              else if (attr === 'src' && n.src) v = String(n.src);
              else v = n.getAttribute(attr);
              if (v !== null && v !== undefined) out.push(String(v));
            }
            return JSON.stringify(out);
            """, args: ["sel": target, "label": target, "attr": attribute], in: tab.webView)
        guard let text = json as? String, let data = text.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    func screenshot() async throws -> Data {
        let tab = try await currentTab()
        let image: UIImage? = await withCheckedContinuation { continuation in
            tab.webView.takeSnapshot(with: nil) { image, _ in continuation.resume(returning: image) }
        }
        guard let data = image?.pngData() else { throw AutomationError("Couldn't capture the page.") }
        return data
    }

    enum HistoryAction { case back, forward, reload }

    func history(_ action: HistoryAction) async throws {
        let tab = try await currentTab()
        switch action {
        case .back:
            guard tab.webView.canGoBack else { throw AutomationError("There's no previous page.") }
            tab.webView.goBack()
        case .forward:
            guard tab.webView.canGoForward else { throw AutomationError("There's no next page.") }
            tab.webView.goForward()
        case .reload:
            tab.webView.reload()
        }
        try await waitForLoad(tab)
    }

    // MARK: Tabs & convenience wrappers (keep UIKit objects on the main actor)

    func tabURLs() async throws -> [String] {
        try await browser().automationTabURLs()
    }

    func selectTab(number: Int) async throws {
        guard try await browser().automationSelectTab(at: number - 1) else {
            throw AutomationError("There's no tab number \(number).")
        }
    }

    func closeCurrentTab() async throws {
        try await browser().automationCloseCurrentTab()
    }

    func waitForCurrentPage(timeout: TimeInterval) async throws {
        try await waitForLoad(currentTab(), timeout: timeout)
    }

    func waitForElementOnCurrentPage(_ target: String, timeout: TimeInterval) async throws -> Bool {
        try await waitForElement(target, in: currentTab(), timeout: timeout)
    }

    // MARK: Recorded automations

    /// Runs every step on the current tab. Steps marked "Shortcut input"
    /// take the next line of `input`. Returns the final page's URL.
    func run(_ automation: BrowserAutomation, input: String?) async throws -> String {
        var inputs = (input ?? "").components(separatedBy: .newlines)
        if input == nil || input?.isEmpty == true { inputs = [] }
        AppLog.shared.log("Running automation “\(automation.name)” (\(automation.steps.count) steps)", category: "automation")

        for (index, step) in automation.steps.enumerated() {
            var value = step.value ?? ""
            if step.usesInput {
                guard !inputs.isEmpty else {
                    throw AutomationError("Step \(index + 1) (\(step.kind.title)) needs a value from the Shortcut's Input — give it one line per input step.")
                }
                value = inputs.removeFirst()
            }
            do {
                try await perform(step, value: value)
            } catch {
                throw AutomationError("Step \(index + 1) — \(step.summary): \(error.localizedDescription)")
            }
        }
        return try await pageDetail(.url)
    }

    private func perform(_ step: AutomationStep, value: String) async throws {
        switch step.kind {
        case .open:
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: text.contains("://") ? text : "https://" + text) else {
                throw AutomationError("“\(value)” isn't a URL.")
            }
            try await navigate(to: url)
        case .tap:
            try await tap(step.selector, label: step.label)
        case .type:
            try await type(value, into: step.selector, label: step.label)
        case .select:
            try await select(value, in: step.selector, label: step.label)
        case .pressEnter:
            try await pressEnter(step.selector, label: step.label)
        case .scroll:
            try await scroll(value.isEmpty ? "down" : value)
        case .wait:
            let seconds = min(max(Double(value) ?? 1, 0), 120)
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        case .waitFor:
            let tab = try await currentTab()
            guard try await waitForElement(step.selector, label: step.label, in: tab, timeout: 20) else {
                throw AutomationError("\(describe(step.selector, step.label)) never appeared.")
            }
        case .back:
            try await history(.back)
        case .javascript:
            _ = try await javascript(value)
        }
    }
}
