import Foundation
import GRDB

public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var url: String
    public var title: String
    public var visitCount: Int
    public var lastVisitedAt: Date
    public var createdAt: Date

    public init(id: Int64? = nil, url: String, title: String, visitCount: Int = 1, lastVisitedAt: Date = Date(), createdAt: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisitedAt = lastVisitedAt
        self.createdAt = createdAt
    }
}

extension HistoryEntry: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "history"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
