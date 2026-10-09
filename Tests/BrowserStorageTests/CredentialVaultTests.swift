import Testing
import Foundation
import GRDB
@testable import BrowserStorage

struct CredentialVaultTests {
    private func makeVault(key: Data = Data(repeating: 7, count: 32)) throws -> (CredentialVault, AppDatabase, () -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HyperBrowserTests-\(UUID().uuidString).sqlite")
        let db = try AppDatabase(path: url.path)
        return (CredentialVault(database: db, keys: StaticKeyProvider(data: key)), db, { try? FileManager.default.removeItem(at: url) })
    }

    @Test func roundTrip() throws {
        let (vault, _, cleanup) = try makeVault(); defer { cleanup() }
        try vault.save(origin: "https://a.com", username: "me", password: "pä$$wörd")
        #expect(try vault.password(origin: "https://a.com", username: "me") == "pä$$wörd")
        #expect(try vault.password(origin: "https://a.com", username: "other") == nil)
    }

    @Test func passwordIsNeverStoredInTheClear() throws {
        let (vault, db, cleanup) = try makeVault(); defer { cleanup() }
        try vault.save(origin: "https://a.com", username: "me", password: "hunter2-secret")
        let raw = try db.dbPool.read { try Data.fetchAll($0, sql: "SELECT sealedPassword FROM credentials") }
        #expect(raw.count == 1)
        #expect(raw[0].range(of: Data("hunter2-secret".utf8)) == nil)
    }

    @Test func savingAgainUpdatesInsteadOfDuplicating() throws {
        let (vault, _, cleanup) = try makeVault(); defer { cleanup() }
        try vault.save(origin: "https://a.com", username: "me", password: "one")
        try vault.save(origin: "https://a.com", username: "me", password: "two")
        #expect(try vault.allLogins().count == 1)
        #expect(try vault.password(origin: "https://a.com", username: "me") == "two")
    }

    @Test func loginsAreScopedToTheExactOrigin() throws {
        let (vault, _, cleanup) = try makeVault(); defer { cleanup() }
        try vault.save(origin: "https://a.com", username: "me", password: "x")
        try vault.save(origin: "https://evil-a.com", username: "me", password: "y")
        #expect(try vault.logins(forOrigin: "https://a.com").map(\.origin) == ["https://a.com"])
        #expect(try vault.logins(forOrigin: "https://sub.a.com").isEmpty)
    }

    @Test func wrongKeyCannotOpenTheBlob() throws {
        let (vault, db, cleanup) = try makeVault(); defer { cleanup() }
        try vault.save(origin: "https://a.com", username: "me", password: "x")
        let other = CredentialVault(database: db, keys: StaticKeyProvider(data: Data(repeating: 9, count: 32)))
        #expect(throws: VaultError.corrupted) { try other.password(origin: "https://a.com", username: "me") }
    }

    @Test func blobCopiedOntoAnotherAccountFailsToOpen() throws {
        let (vault, db, cleanup) = try makeVault(); defer { cleanup() }
        try vault.save(origin: "https://a.com", username: "alice", password: "alice-pw")
        try vault.save(origin: "https://a.com", username: "bob", password: "bob-pw")
        try db.dbPool.write { db in
            try db.execute(sql: "UPDATE credentials SET sealedPassword = (SELECT sealedPassword FROM credentials WHERE username = 'alice') WHERE username = 'bob'")
        }
        #expect(throws: VaultError.corrupted) { try vault.password(origin: "https://a.com", username: "bob") }
    }

    @Test func deleteRemovesTheLogin() throws {
        let (vault, _, cleanup) = try makeVault(); defer { cleanup() }
        try vault.save(origin: "https://a.com", username: "me", password: "x")
        let id = try #require(try vault.allLogins().first?.id)
        try vault.delete(id: id)
        #expect(try vault.allLogins().isEmpty)
    }
}
