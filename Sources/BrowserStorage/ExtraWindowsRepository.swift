import Foundation
import GRDB

/// One tab of a window opened after the first one, as saved for the next launch.
public struct ExtraWindowTab: Sendable, Equatable {
    public let url: String
    public let interactionState: Data?
    public let title: String?
    public let spaceIndex: Int
    public let isActive: Bool

    public init(url: String, interactionState: Data?, title: String?, spaceIndex: Int, isActive: Bool) {
        self.url = url; self.interactionState = interactionState; self.title = title; self.spaceIndex = spaceIndex; self.isActive = isActive
    }
}

private struct ExtraWindowTabRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "extraWindowTabs"
    var windowIndex: Int
    var orderIndex: Int
    var url: String
    var interactionState: Data?
    var title: String?
    var spaceIndex: Int
    var isActive: Bool
}

/// The windows opened with ⌘N and their tabs. Private tabs never get here (the caller passes savable tabs only).
public struct ExtraWindowsRepository: Sendable {
    private let dbPool: DatabasePool

    public init(database: AppDatabase = .shared) { self.dbPool = database.dbPool }

    /// Replaces everything saved. A window with no tab is not saved.
    public func save(_ windows: [[ExtraWindowTab]]) throws {
        try dbPool.write { db in
            try ExtraWindowTabRow.deleteAll(db)
            for (windowIndex, tabs) in windows.enumerated() {
                for (orderIndex, tab) in tabs.enumerated() {
                    try ExtraWindowTabRow(windowIndex: windowIndex, orderIndex: orderIndex, url: tab.url, interactionState: tab.interactionState,
                                          title: tab.title, spaceIndex: tab.spaceIndex, isActive: tab.isActive).insert(db)
                }
            }
        }
    }

    /// Windows in the order they were saved, each with its tabs in order.
    public func load() throws -> [[ExtraWindowTab]] {
        try dbPool.read { db in
            let rows = try ExtraWindowTabRow.order(Column("windowIndex"), Column("orderIndex")).fetchAll(db)
            var grouped: [Int: [ExtraWindowTab]] = [:]
            for row in rows {
                grouped[row.windowIndex, default: []].append(ExtraWindowTab(url: row.url, interactionState: row.interactionState, title: row.title, spaceIndex: row.spaceIndex, isActive: row.isActive))
            }
            return grouped.keys.sorted().map { grouped[$0] ?? [] }
        }
    }
}
