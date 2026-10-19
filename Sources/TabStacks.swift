import Foundation

/// Names and collapsed state for tab stacks (the accordion groups in the
/// sidebar). The membership itself lives on each Tab (`stackID`); this only
/// stores per-stack display state, keyed by the stack's UUID string.
final class TabStackStore {
    static let shared = TabStackStore()
    static let didChange = Notification.Name("UndirectTabStacksDidChange")

    private let nameKey = "s.tabStackNames"
    private let collapsedKey = "s.tabStackCollapsed"
    private var names: [String: String]
    private var collapsed: Set<String>

    private init() {
        names = (UserDefaults.standard.dictionary(forKey: nameKey) as? [String: String]) ?? [:]
        collapsed = Set(UserDefaults.standard.stringArray(forKey: collapsedKey) ?? [])
    }

    func name(_ id: UUID) -> String {
        let n = names[id.uuidString] ?? ""
        return n.isEmpty ? "Stack" : n
    }

    func setName(_ name: String, for id: UUID) {
        names[id.uuidString] = name
        persist()
    }

    func isCollapsed(_ id: UUID) -> Bool { collapsed.contains(id.uuidString) }

    func setCollapsed(_ value: Bool, for id: UUID) {
        if value { collapsed.insert(id.uuidString) } else { collapsed.remove(id.uuidString) }
        persist()
    }

    func toggleCollapsed(_ id: UUID) { setCollapsed(!isCollapsed(id), for: id) }

    /// Drops state for a stack no tab belongs to any more.
    func forget(_ id: UUID) {
        names[id.uuidString] = nil
        collapsed.remove(id.uuidString)
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(names, forKey: nameKey)
        UserDefaults.standard.set(Array(collapsed), forKey: collapsedKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
