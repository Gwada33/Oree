import Foundation

/// A named, collapsible bundle of tabs inside one space.
public struct TabGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var spaceIndex: Int
    public var collapsed: Bool

    public init(id: UUID = UUID(), name: String, spaceIndex: Int, collapsed: Bool = false) {
        self.id = id; self.name = name; self.spaceIndex = spaceIndex; self.collapsed = collapsed
    }
}

/// One line of the sidebar's tab list.
public enum TabListRow: Equatable, Sendable {
    case groupHeader(UUID)
    case tab(UUID, indented: Bool)
    /// "Pages libres": shown only when the space has groups and loose tabs.
    case looseHeader
}

/// Pure rule for what the tab column shows for one space: groups first (in their own order, each
/// followed by its tabs unless collapsed), then the loose tabs. Tab order inside a block is the
/// global tab order.
public enum TabListLayout {
    public struct Item: Sendable {
        public let id: UUID
        public let spaceIndex: Int
        public let groupID: UUID?
        public init(id: UUID, spaceIndex: Int, groupID: UUID?) {
            self.id = id; self.spaceIndex = spaceIndex; self.groupID = groupID
        }
    }

    public static func rows(tabs: [Item], groups: [TabGroup], space: Int) -> [TabListRow] {
        let mine = tabs.filter { $0.spaceIndex == space }
        let spaceGroups = groups.filter { $0.spaceIndex == space }
        let known = Set(spaceGroups.map(\.id))
        var rows: [TabListRow] = []
        for group in spaceGroups {
            rows.append(.groupHeader(group.id))
            guard !group.collapsed else { continue }
            rows += mine.filter { $0.groupID == group.id }.map { .tab($0.id, indented: true) }
        }
        let loose = mine.filter { $0.groupID.map { !known.contains($0) } ?? true }
        if !spaceGroups.isEmpty && !loose.isEmpty { rows.append(.looseHeader) }
        rows += loose.map { .tab($0.id, indented: false) }
        return rows
    }

    /// Tabs hidden because their group is collapsed.
    public static func hiddenCount(in group: TabGroup, tabs: [Item]) -> Int {
        group.collapsed ? tabs.filter { $0.groupID == group.id }.count : 0
    }
}
