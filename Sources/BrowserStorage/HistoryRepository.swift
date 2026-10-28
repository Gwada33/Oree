import Foundation
import GRDB

/// Read/write access to browsing history, including FTS5 full-text search.
public struct HistoryRepository: Sendable {
    private let dbPool: DatabasePool

    public init(database: AppDatabase = .shared) {
        self.dbPool = database.dbPool
    }

    /// Records a visit: bumps `visitCount` and `lastVisitedAt` if the URL is
    /// already known, inserts a fresh row otherwise.
    public func recordVisit(url: String, title: String) throws {
        try dbPool.write { db in
            if var existing = try HistoryEntry.filter(Column("url") == url).fetchOne(db) {
                existing.visitCount += 1
                existing.title = title
                existing.lastVisitedAt = Date()
                try existing.update(db)
            } else {
                var entry = HistoryEntry(url: url, title: title)
                try entry.insert(db)
            }
        }
    }

    public func recent(limit: Int = 50) throws -> [HistoryEntry] {
        try dbPool.read { db in
            try HistoryEntry.order(Column("lastVisitedAt").desc).limit(limit).fetchAll(db)
        }
    }

    /// Full-text search across titles and URLs via the `history_fts` index.
    public func search(matching query: String, limit: Int = 20) throws -> [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let pattern = FTS5Pattern(matchingAllTokensIn: trimmed) else { return [] }
        return try dbPool.read { db in
            try HistoryEntry.fetchAll(db, sql: """
                SELECT history.* FROM history
                JOIN history_fts ON history_fts.rowid = history.id
                WHERE history_fts MATCH ?
                ORDER BY history.lastVisitedAt DESC
                LIMIT ?
                """, arguments: [pattern, limit])
        }
    }

    /// Addresses containing `text`, most visited first (then most recent): the raw material of the address bar's inline completion.
    public func addresses(containing text: String, limit: Int = 40) throws -> [String] {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return try dbPool.read { db in
            try String.fetchAll(db, sql: """
                SELECT url FROM history WHERE url LIKE ? ESCAPE '\\' ORDER BY visitCount DESC, lastVisitedAt DESC LIMIT ?
                """, arguments: ["%\(escaped)%", limit])
        }
    }

    /// Les entrées dont l'adresse ou le titre contient `text` (tout si vide), visitées entre `since` et `until`, les plus récentes d'abord.
    public func entries(matching text: String, since: Date?, until: Date?, limit: Int) throws -> [HistoryEntry] {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return try dbPool.read { db in
            try HistoryEntry.fetchAll(db, sql: """
                SELECT * FROM history WHERE (url LIKE ?1 ESCAPE '\\' OR title LIKE ?1 ESCAPE '\\') AND lastVisitedAt >= ?2 AND lastVisitedAt <= ?3
                ORDER BY lastVisitedAt DESC LIMIT ?4
                """, arguments: ["%\(escaped)%", since ?? .distantPast, until ?? .distantFuture, limit])
        }
    }

    /// Les pages les plus visitées.
    public func top(limit: Int) throws -> [HistoryEntry] {
        try dbPool.read { db in try HistoryEntry.order(Column("visitCount").desc, Column("lastVisitedAt").desc).limit(limit).fetchAll(db) }
    }

    @discardableResult
    public func remove(url: String) throws -> Bool {
        try dbPool.write { db in try HistoryEntry.filter(Column("url") == url).deleteAll(db) > 0 }
    }

    @discardableResult
    public func remove(from start: Date, to end: Date) throws -> Int {
        try dbPool.write { db in try HistoryEntry.filter(Column("lastVisitedAt") >= start && Column("lastVisitedAt") <= end).deleteAll(db) }
    }

    public func clear() throws {
        try dbPool.write { db in _ = try HistoryEntry.deleteAll(db) }
    }
}
