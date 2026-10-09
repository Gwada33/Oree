import Foundation
import GRDB

public struct ReadingItem: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "readingList"
    public var id: Int64?
    public var url: String
    public var title: String
    public var addedAt: Date

    public init(id: Int64? = nil, url: String, title: String, addedAt: Date = Date()) {
        self.id = id; self.url = url; self.title = title; self.addedAt = addedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// "Liste de lecture": pages kept to read later (title + address only, nothing is downloaded).
public struct ReadingListRepository: Sendable {
    private let dbPool: DatabasePool
    public init(database: AppDatabase = .shared) { self.dbPool = database.dbPool }

    /// Adds a page; saving the same address again just refreshes its title and moves it to the top.
    public func add(url: String, title: String) throws {
        try dbPool.write { db in
            _ = try ReadingItem.filter(Column("url") == url).deleteAll(db)
            var item = ReadingItem(url: url, title: title)
            try item.insert(db)
        }
    }

    public func contains(url: String) throws -> Bool {
        try dbPool.read { db in try ReadingItem.filter(Column("url") == url).fetchCount(db) > 0 }
    }

    public func remove(url: String) throws {
        try dbPool.write { db in _ = try ReadingItem.filter(Column("url") == url).deleteAll(db) }
    }

    public func all() throws -> [ReadingItem] {
        try dbPool.read { db in try ReadingItem.order(Column("addedAt").desc, Column("id").desc).fetchAll(db) }
    }
}
