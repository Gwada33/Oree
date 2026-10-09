import Foundation
import GRDB

public struct AddressBarSuggestion: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let url: String
    public let title: String
    public let isBookmarked: Bool
}

/// Ranks address-bar suggestions by a frecency score inspired by Firefox's
/// algorithm: visit count weighted by how recently the page was last
/// visited, using the same decay buckets Firefox documents (4 / 14 / 31 / 90
/// days). This is a deliberately simplified re-implementation — we store one
/// aggregate row per URL rather than a full per-visit log, so there's no
/// per-visit-type weighting — not a byte-for-byte port of Firefox's `Place`
/// frecency computation.
public struct SuggestionProvider: Sendable {
    private let dbPool: DatabasePool

    public init(database: AppDatabase = .shared) {
        self.dbPool = database.dbPool
    }

    public func suggestions(for query: String, limit: Int = 8) throws -> [AddressBarSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let like = "%\(trimmed)%"

        return try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT h.id, h.url, h.title,
                       h.visitCount *
                       CASE
                         WHEN julianday('now') - julianday(h.lastVisitedAt) <= 4  THEN 100
                         WHEN julianday('now') - julianday(h.lastVisitedAt) <= 14 THEN 70
                         WHEN julianday('now') - julianday(h.lastVisitedAt) <= 31 THEN 50
                         WHEN julianday('now') - julianday(h.lastVisitedAt) <= 90 THEN 30
                         ELSE 10
                       END AS frecency,
                       EXISTS(SELECT 1 FROM bookmarks b WHERE b.url = h.url) AS isBookmarked
                FROM history h
                WHERE h.url LIKE ? OR h.title LIKE ?
                ORDER BY frecency DESC, h.visitCount DESC
                LIMIT ?
                """, arguments: [like, like, limit])

            return rows.map { row in
                AddressBarSuggestion(
                    id: row["id"],
                    url: row["url"],
                    title: row["title"],
                    isBookmarked: row["isBookmarked"]
                )
            }
        }
    }
}
