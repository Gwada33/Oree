import Foundation
import GRDB

public struct Bookmark: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var url: String
    public var title: String
    public var createdAt: Date
    /// The space this favorite belongs to; `nil` = shown in every space.
    public var spaceIndex: Int?

    public init(id: Int64? = nil, url: String, title: String, createdAt: Date = Date(), spaceIndex: Int? = nil) {
        self.spaceIndex = spaceIndex
        self.id = id
        self.url = url
        self.title = title
        self.createdAt = createdAt
    }
}

extension Bookmark: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "bookmarks"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
