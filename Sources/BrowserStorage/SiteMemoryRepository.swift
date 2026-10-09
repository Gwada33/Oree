import Foundation
import GRDB
import BrowserCore

private struct SiteMemoryRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "siteMemory"
    var host: String
    var samples: Int
    var averageMB: Double
    var peakMB: Double
    var updatedAt: Date
}

/// Persists what's been learned about each site's memory use, so it survives restarts.
public struct SiteMemoryRepository: Sendable {
    private let dbPool: DatabasePool

    public init(database: AppDatabase = .shared) {
        self.dbPool = database.dbPool
    }

    /// Folds one measurement (in MB) into the site's profile.
    public func record(host: String, megabytes: Double) throws {
        guard megabytes.isFinite, megabytes > 0 else { return }
        try dbPool.write { db in
            var row = try SiteMemoryRow.fetchOne(db, key: host)
                ?? SiteMemoryRow(host: host, samples: 0, averageMB: megabytes, peakMB: megabytes, updatedAt: Date())
            row.averageMB = SiteMemoryPolicy.updatedAverage(old: row.averageMB, samples: row.samples, new: megabytes)
            row.peakMB = max(row.peakMB, megabytes)
            row.samples += 1
            row.updatedAt = Date()
            try row.save(db)
        }
    }

    public func profile(host: String) throws -> SiteProfile? {
        try dbPool.read { db in try SiteMemoryRow.fetchOne(db, key: host).map(Self.model) }
    }

    /// The heaviest sites, most memory first (only those measured enough times to be reliable).
    public func heaviest(limit: Int = 5) throws -> [SiteProfile] {
        try dbPool.read { db in
            try SiteMemoryRow
                .filter(Column("samples") >= SiteMemoryPolicy.minimumSamples)
                .order(Column("averageMB").desc)
                .limit(limit)
                .fetchAll(db)
                .map(Self.model)
        }
    }

    public func clear() throws {
        try dbPool.write { db in _ = try SiteMemoryRow.deleteAll(db) }
    }

    private static func model(_ row: SiteMemoryRow) -> SiteProfile {
        SiteProfile(host: row.host, samples: row.samples, averageMB: row.averageMB, peakMB: row.peakMB)
    }
}
