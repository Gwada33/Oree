import Foundation
import GRDB

/// Les pages lues, pour que Luciole puisse les retrouver : titre, site, extrait du texte (8 000 caractères au plus), date de lecture. Recherche plein texte (FTS5).
/// Sur ce Mac seulement ; ce que décide de garder `PageMemoryPolicy` est tout ce qui entre ici.
public struct PageMemoryRepository: Sendable {
    public struct Hit: Equatable, Sendable { public var title: String; public var host: String; public var url: String; public var snippet: String; public var readAt: Date }

    private let dbPool: DatabasePool
    public init(database: AppDatabase = .shared) { dbPool = database.dbPool }

    public func remember(url: String, host: String, title: String, text: String, at date: Date = Date()) throws {
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO pageMemory (url, host, title, body, readAt, visits) VALUES (?, ?, ?, ?, ?, 1)
                ON CONFLICT(url) DO UPDATE SET title = excluded.title, body = excluded.body, readAt = excluded.readAt, visits = visits + 1
                """, arguments: [url, host, title, text, date])
        }
    }

    /// Les pages qui contiennent TOUS les mots, les plus récentes d'abord, avec l'extrait qui entoure le mot trouvé.
    public func search(words: [String], limit: Int = 4) throws -> [Hit] {
        let clean = words.map { $0.filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return [] }
        let pattern = FTS5Pattern(matchingAllTokensIn: clean.joined(separator: " "))
        guard let pattern else { return [] }
        return try dbPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT pageMemory.title, pageMemory.host, pageMemory.url, pageMemory.readAt,
                       snippet(pageMemory_fts, 1, '', '', ' … ', 24) AS snippet
                FROM pageMemory JOIN pageMemory_fts ON pageMemory_fts.rowid = pageMemory.id
                WHERE pageMemory_fts MATCH ?
                ORDER BY pageMemory.readAt DESC LIMIT ?
                """, arguments: [pattern, limit]).map {
                Hit(title: $0["title"], host: $0["host"], url: $0["url"], snippet: $0["snippet"], readAt: $0["readAt"])
            }
        }
    }

    public func count() throws -> Int { try dbPool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pageMemory") ?? 0 } }

    /// Oublie tout, ou les pages d'un site.
    public func forgetAll() throws { try dbPool.write { try $0.execute(sql: "DELETE FROM pageMemory") } }
    public func forget(host: String) throws { try dbPool.write { try $0.execute(sql: "DELETE FROM pageMemory WHERE host = ?", arguments: [host]) } }

    /// Garde les `days` derniers jours.
    public func purge(olderThanDays days: Int, now: Date = Date()) throws {
        let limit = now.addingTimeInterval(-Double(days) * 86_400)
        try dbPool.write { try $0.execute(sql: "DELETE FROM pageMemory WHERE readAt < ?", arguments: [limit]) }
    }
}
