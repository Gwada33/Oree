import Foundation
import CryptoKit
import GRDB
import Security

/// Where the vault's 256-bit master key lives.
public protocol VaultKeyProvider: Sendable {
    func masterKey() throws -> SymmetricKey
}

public enum VaultError: Error, Equatable {
    case keychain(OSStatus)
    case corrupted
}

/// Master key stored as a generic-password Keychain item, created on first use.
public struct KeychainKeyProvider: VaultKeyProvider {
    private let service: String
    private let account: String

    public init(service: String = "com.nolhan.hyperbrowser.vault", account: String = "master-key") {
        self.service = service
        self.account = account
    }

    public func masterKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else { throw VaultError.keychain(status) }

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            kSecAttrLabel as String: "HyperBrowser — clé du coffre de mots de passe",
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw VaultError.keychain(addStatus) }
        return key
    }
}

/// Fixed in-memory key, for tests.
public struct StaticKeyProvider: VaultKeyProvider {
    private let data: Data
    public init(data: Data = Data(repeating: 7, count: 32)) { self.data = data }
    public func masterKey() throws -> SymmetricKey { SymmetricKey(data: data) }
}

public struct SavedLogin: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let origin: String
    public let username: String
    public let updatedAt: Date
}

private struct CredentialRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "credentials"
    var id: Int64?
    var origin: String
    var username: String
    var sealedPassword: Data
    var createdAt: Date
    var updatedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Encrypted login storage. Passwords are sealed with ChaChaPoly under a
/// Keychain-held key; the origin and username are bound in as authenticated
/// data, so a sealed blob copied onto another row fails to open.
public struct CredentialVault: Sendable {
    private let dbPool: DatabasePool
    private let keys: VaultKeyProvider

    public init(database: AppDatabase = .shared, keys: VaultKeyProvider = KeychainKeyProvider()) {
        self.dbPool = database.dbPool
        self.keys = keys
    }

    private static func aad(origin: String, username: String) -> Data {
        Data("\(origin)\u{0}\(username)".utf8)
    }

    public func save(origin: String, username: String, password: String) throws {
        let key = try keys.masterKey()
        let sealed = try ChaChaPoly.seal(Data(password.utf8), using: key, authenticating: Self.aad(origin: origin, username: username))
        let now = Date()
        try dbPool.write { db in
            if var existing = try CredentialRow
                .filter(Column("origin") == origin && Column("username") == username).fetchOne(db) {
                existing.sealedPassword = sealed.combined
                existing.updatedAt = now
                try existing.update(db)
            } else {
                var row = CredentialRow(id: nil, origin: origin, username: username, sealedPassword: sealed.combined, createdAt: now, updatedAt: now)
                try row.insert(db)
            }
        }
    }

    /// Logins for an exact origin, most recently updated first. No passwords.
    public func logins(forOrigin origin: String) throws -> [SavedLogin] {
        try dbPool.read { db in
            try CredentialRow.filter(Column("origin") == origin).order(Column("updatedAt").desc).fetchAll(db).map(Self.model)
        }
    }

    public func allLogins() throws -> [SavedLogin] {
        try dbPool.read { db in
            try CredentialRow.order(Column("origin"), Column("username")).fetchAll(db).map(Self.model)
        }
    }

    public func password(origin: String, username: String) throws -> String? {
        guard let row = try dbPool.read({ db in
            try CredentialRow.filter(Column("origin") == origin && Column("username") == username).fetchOne(db)
        }) else { return nil }
        do {
            let box = try ChaChaPoly.SealedBox(combined: row.sealedPassword)
            let data = try ChaChaPoly.open(box, using: try keys.masterKey(), authenticating: Self.aad(origin: origin, username: username))
            return String(data: data, encoding: .utf8)
        } catch is CryptoKitError {
            throw VaultError.corrupted
        }
    }

    public func delete(id: Int64) throws {
        try dbPool.write { db in _ = try CredentialRow.deleteOne(db, key: id) }
    }

    public func deleteAll() throws {
        try dbPool.write { db in _ = try CredentialRow.deleteAll(db) }
    }

    private static func model(_ row: CredentialRow) -> SavedLogin {
        SavedLogin(id: row.id ?? 0, origin: row.origin, username: row.username, updatedAt: row.updatedAt)
    }
}
