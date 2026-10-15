import Foundation
import GRDB

public struct Note: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "notes"
    public var id: Int64?
    public var body: String
    /// The page this note is about, if any.
    public var url: String?
    public var updatedAt: Date

    public init(id: Int64? = nil, body: String = "", url: String? = nil, updatedAt: Date = Date()) {
        self.id = id; self.body = body; self.url = url; self.updatedAt = updatedAt
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// First non-empty line, shortened: what the list shows.
    public var title: String {
        let line = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "Note vide"
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }
}

/// Notes: free text kept on this Mac, optionally tied to a page.
public struct NoteRepository: Sendable {
    private let dbPool: DatabasePool
    public init(database: AppDatabase = .shared) { self.dbPool = database.dbPool }

    /// Inserts a new note (no id yet) or updates an existing one; returns it with its id.
    @discardableResult
    public func save(_ note: Note) throws -> Note {
        try dbPool.write { db in
            var saved = note
            saved.updatedAt = Date()
            try saved.save(db)
            return saved
        }
    }

    /// Newest first.
    public func all() throws -> [Note] {
        try dbPool.read { db in try Note.order(Column("updatedAt").desc, Column("id").desc).fetchAll(db) }
    }

    /// The most recently edited note about this page.
    public func latest(forURL url: String) throws -> Note? {
        try dbPool.read { db in try Note.filter(Column("url") == url).order(Column("updatedAt").desc).fetchOne(db) }
    }

    public func delete(id: Int64) throws {
        try dbPool.write { db in _ = try Note.deleteOne(db, key: id) }
    }

    /// A note nobody typed in is not worth keeping.
    public func deleteEmpty() throws {
        try dbPool.write { db in _ = try Note.filter(Column("body") == "").deleteAll(db) }
    }
}
