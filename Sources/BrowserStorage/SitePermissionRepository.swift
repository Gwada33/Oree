import Foundation
import GRDB

public enum SitePermission: String, Sendable, CaseIterable {
    case camera, microphone, location
}

public enum PermissionDecision: String, Sendable {
    case allow, deny
}

public enum PermissionScope: String, Sendable {
    /// Forgotten at next launch (the default).
    case session
    /// Kept until the user resets it.
    case permanent
}

public struct StoredPermission: Sendable, Equatable {
    public let origin: String
    public let permission: SitePermission
    public let decision: PermissionDecision
    public let scope: PermissionScope
}

private struct PermissionRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sitePermissions"
    var origin: String
    var permission: String
    var decision: String
    var scope: String
    var updatedAt: Date
}

public struct SitePermissionRepository: Sendable {
    private let dbPool: DatabasePool

    public init(database: AppDatabase = .shared) {
        self.dbPool = database.dbPool
    }

    /// Origin key: scheme + host + non-default port, e.g. "https://example.com".
    public static func origin(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        if let port = url.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    public func decision(origin: String, permission: SitePermission) throws -> StoredPermission? {
        try dbPool.read { db in
            try PermissionRow
                .filter(Column("origin") == origin && Column("permission") == permission.rawValue)
                .fetchOne(db)
                .flatMap(Self.model)
        }
    }

    public func set(origin: String, permission: SitePermission, decision: PermissionDecision, scope: PermissionScope = .session) throws {
        try dbPool.write { db in
            try PermissionRow(origin: origin, permission: permission.rawValue, decision: decision.rawValue, scope: scope.rawValue, updatedAt: Date())
                .save(db)
        }
    }

    public func all() throws -> [StoredPermission] {
        try dbPool.read { db in
            try PermissionRow.order(Column("origin"), Column("permission")).fetchAll(db).compactMap(Self.model)
        }
    }

    public func reset(origin: String, permission: SitePermission? = nil) throws {
        try dbPool.write { db in
            var request = PermissionRow.filter(Column("origin") == origin)
            if let permission { request = request.filter(Column("permission") == permission.rawValue) }
            _ = try request.deleteAll(db)
        }
    }

    /// Call at launch: session-scoped decisions don't outlive the session.
    public func purgeSessionScoped() throws {
        try dbPool.write { db in
            _ = try PermissionRow.filter(Column("scope") == PermissionScope.session.rawValue).deleteAll(db)
        }
    }

    private static func model(_ row: PermissionRow) -> StoredPermission? {
        guard let permission = SitePermission(rawValue: row.permission),
              let decision = PermissionDecision(rawValue: row.decision),
              let scope = PermissionScope(rawValue: row.scope) else { return nil }
        return StoredPermission(origin: row.origin, permission: permission, decision: decision, scope: scope)
    }
}
