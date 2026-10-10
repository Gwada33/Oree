import Foundation
import GRDB
import BrowserCore

private struct BoostRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "boosts"
    var host: String
    var prompt: String
    var rulesJSON: String
    var calm: Bool
    var enabled: Bool
    var updatedAt: Date

    init(_ boost: Boost) {
        host = boost.host; prompt = boost.prompt; calm = boost.calm; enabled = boost.enabled; updatedAt = boost.updatedAt
        rulesJSON = (try? JSONEncoder().encode(boost.rules)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
    var boost: Boost {
        let rules = (try? JSONDecoder().decode([BoostRule].self, from: Data(rulesJSON.utf8))) ?? []
        return Boost(host: host, prompt: prompt, rules: rules, calm: calm, enabled: enabled, updatedAt: updatedAt)
    }
}

/// What the user changed on each site (their "boosts"), kept on this Mac only.
public struct BoostRepository: Sendable {
    private let dbPool: DatabasePool

    public init(database: AppDatabase = .shared) { self.dbPool = database.dbPool }

    public func all() throws -> [Boost] {
        try dbPool.read { db in try BoostRow.order(Column("host")).fetchAll(db).map(\.boost) }
    }

    /// The boost of `host` or of its parent domain ("m.example.com" → "example.com").
    public func boost(for host: String?) throws -> Boost? {
        guard let host = ProtectionPolicy.normalized(host) else { return nil }
        return try all().first { host == $0.host || host.hasSuffix("." + $0.host) }
    }

    public func save(_ boost: Boost) throws {
        var stored = boost
        stored.host = ProtectionPolicy.normalized(boost.host) ?? boost.host
        stored.updatedAt = Date()
        try dbPool.write { db in try BoostRow(stored).save(db) }
    }

    public func remove(host: String) throws {
        guard let host = ProtectionPolicy.normalized(host) else { return }
        try dbPool.write { db in _ = try BoostRow.deleteOne(db, key: host) }
    }

    public func clear() throws { try dbPool.write { db in _ = try BoostRow.deleteAll(db) } }
}
