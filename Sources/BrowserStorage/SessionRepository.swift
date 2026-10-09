import Foundation
import GRDB
import BrowserCore

/// One open tab's restorable state: its URL (used only as a fallback/display
/// hint — the real restore path is `interactionState`, which also captures
/// the tab's own back-forward history and scroll position), and the raw
/// `WKWebView.interactionState` blob captured by the UI layer.
public struct TabSnapshot: Sendable {
    public let orderIndex: Int
    public let url: String
    public let isPrivate: Bool
    public let interactionState: Data?
    public let title: String?
    public let spaceIndex: Int
    public let groupID: String?

    public init(orderIndex: Int, url: String, isPrivate: Bool, interactionState: Data?, title: String? = nil, spaceIndex: Int = 0, groupID: String? = nil) {
        self.spaceIndex = spaceIndex
        self.groupID = groupID
        self.orderIndex = orderIndex
        self.url = url
        self.isPrivate = isPrivate
        self.interactionState = interactionState
        self.title = title
    }
}

private struct TabSessionRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "tabSessions"
    var orderIndex: Int
    var url: String
    var isPrivate: Bool
    var interactionState: Data?
    var title: String?
    var spaceIndex: Int
    var groupID: String?
    var updatedAt: Date
}

/// Persists the open-tab list so it survives a quit/relaunch. Private tabs
/// are never written here (their whole point is to leave no trace).
public struct SessionRepository: Sendable {
    private let dbPool: DatabasePool

    public init(database: AppDatabase = .shared) {
        self.dbPool = database.dbPool
    }

    /// Replaces the whole saved session. Called incrementally (navigation,
    /// tab open/close) rather than only at quit, so a crash loses at most
    /// the last few seconds of browsing, not the whole window.
    public func save(_ snapshots: [TabSnapshot]) throws {
        try dbPool.write { db in
            try TabSessionRow.deleteAll(db)
            let now = Date()
            for snapshot in snapshots where !snapshot.isPrivate {
                let row = TabSessionRow(
                    orderIndex: snapshot.orderIndex,
                    url: snapshot.url,
                    isPrivate: snapshot.isPrivate,
                    interactionState: snapshot.interactionState,
                    title: snapshot.title,
                    spaceIndex: snapshot.spaceIndex,
                    groupID: snapshot.groupID,
                    updatedAt: now
                )
                try row.insert(db)
            }
        }
    }

    public func load() throws -> [TabSnapshot] {
        try dbPool.read { db in
            try TabSessionRow
                .order(Column("orderIndex"))
                .fetchAll(db)
                .map { TabSnapshot(orderIndex: $0.orderIndex, url: $0.url, isPrivate: $0.isPrivate, interactionState: $0.interactionState, title: $0.title, spaceIndex: $0.spaceIndex, groupID: $0.groupID) }
        }
    }

    public func clear() throws {
        try dbPool.write { db in _ = try TabSessionRow.deleteAll(db) }
    }
}

private struct TabGroupRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "tabGroups"
    var id: String
    var name: String
    var spaceIndex: Int
    var collapsed: Bool
    var position: Int
}

/// Saved tab groups (name, space, collapsed state, order).
public struct TabGroupRepository: Sendable {
    private let dbPool: DatabasePool
    public init(database: AppDatabase = .shared) { self.dbPool = database.dbPool }

    public func save(_ groups: [TabGroup]) throws {
        try dbPool.write { db in
            try TabGroupRow.deleteAll(db)
            for (position, group) in groups.enumerated() {
                try TabGroupRow(id: group.id.uuidString, name: group.name, spaceIndex: group.spaceIndex,
                                collapsed: group.collapsed, position: position).insert(db)
            }
        }
    }

    public func load() throws -> [TabGroup] {
        try dbPool.read { db in
            try TabGroupRow.order(Column("position")).fetchAll(db).compactMap { row in
                UUID(uuidString: row.id).map { TabGroup(id: $0, name: row.name, spaceIndex: row.spaceIndex, collapsed: row.collapsed) }
            }
        }
    }
}
