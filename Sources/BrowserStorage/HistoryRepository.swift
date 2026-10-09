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

    public func clear() throws {
        try dbPool.write { db in _ = try HistoryEntry.deleteAll(db) }
    }
}
