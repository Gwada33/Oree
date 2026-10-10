import Foundation
import GRDB
import BrowserCore

private struct ResumeRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "resumePoints"
    var key: String
    var title: String
    var videoSeconds: Double?
    var videoDuration: Double?
    var readFraction: Double?
    var anchor: String?
    var updatedAt: Date

    init(_ point: ResumePoint) {
        key = point.key; title = point.title; videoSeconds = point.videoSeconds; videoDuration = point.videoDuration
        readFraction = point.readFraction; anchor = point.anchor; updatedAt = point.updatedAt
    }
    var point: ResumePoint {
        ResumePoint(key: key, title: title, videoSeconds: videoSeconds, videoDuration: videoDuration,
                    readFraction: readFraction, anchor: anchor, updatedAt: updatedAt)
    }
}

/// Where the user was in each page (video position, reading position), kept on this Mac only. Never filled for private tabs
/// (the caller's job) and emptied with the browsing data.
public struct ResumeRepository: Sendable {
    private let dbPool: DatabasePool

    public init(database: AppDatabase = .shared) { self.dbPool = database.dbPool }

    public func point(for key: String) throws -> ResumePoint? {
        try dbPool.read { db in
            guard let point = try ResumeRow.fetchOne(db, key: key)?.point, !ResumePolicy.isExpired(point) else { return nil }
            return point
        }
    }

    /// Updates one part of a page's point. Pass `.some(nil)`-style by using the dedicated clear methods; a part left nil is kept.
    public func update(key: String, title: String, video: (seconds: Double, duration: Double)? = nil,
                       reading: (fraction: Double, anchor: String?)? = nil) throws {
        try dbPool.write { db in
            var row = try ResumeRow.fetchOne(db, key: key) ?? ResumeRow(ResumePoint(key: key, title: title))
            row.title = title
            if let video { row.videoSeconds = video.seconds; row.videoDuration = video.duration }
            if let reading { row.readFraction = reading.fraction; row.anchor = reading.anchor }
            row.updatedAt = Date()
            try row.save(db)
            try Self.prune(db)
        }
    }

    /// The video is finished (or the user restarted it): forget its position, keep the reading one.
    public func clearVideo(key: String) throws { try clear(key: key, video: true) }
    public func clearReading(key: String) throws { try clear(key: key, video: false) }

    private func clear(key: String, video: Bool) throws {
        try dbPool.write { db in
            guard var row = try ResumeRow.fetchOne(db, key: key) else { return }
            if video { row.videoSeconds = nil; row.videoDuration = nil } else { row.readFraction = nil; row.anchor = nil }
            if row.videoSeconds == nil && row.readFraction == nil { _ = try row.delete(db) } else { try row.save(db) }
        }
    }

    /// Most recently updated first (for a future "continue" list).
    public func recent(limit: Int = 20) throws -> [ResumePoint] {
        try dbPool.read { db in try ResumeRow.order(Column("updatedAt").desc).limit(limit).fetchAll(db).map(\.point).filter { ResumePolicy.offer(for: $0) != nil } }
    }

    public func remove(key: String) throws { try dbPool.write { db in _ = try ResumeRow.deleteOne(db, key: key) } }

    public func clear() throws { try dbPool.write { db in _ = try ResumeRow.deleteAll(db) } }

    /// Old entries go, then the oldest beyond the cap.
    private static func prune(_ db: Database) throws {
        let cutoff = Date(timeIntervalSinceNow: -Double(ResumePolicy.keepDays) * 86_400)
        try db.execute(sql: "DELETE FROM resumePoints WHERE updatedAt < ?", arguments: [cutoff])
        try db.execute(sql: "DELETE FROM resumePoints WHERE key NOT IN (SELECT key FROM resumePoints ORDER BY updatedAt DESC LIMIT ?)",
                       arguments: [ResumePolicy.keepEntries])
    }
}
