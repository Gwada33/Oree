import Testing
import Foundation
import BrowserCore
@testable import BrowserStorage

struct CredentialVaultTOTPTests {
    private func makeVault() throws -> (CredentialVault, () -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HyperBrowserTests-\(UUID().uuidString).sqlite")
        return (CredentialVault(database: try AppDatabase(path: url.path), keys: StaticKeyProvider()), { try? FileManager.default.removeItem(at: url) })
    }
    private let config = TOTPConfig(secret: Data("12345678901234567890".utf8), digits: 6, period: 30, issuer: "Exemple", account: "ana")

    @Test func secretRoundTripsAndIsSealed() throws {
        let (vault, cleanup) = try makeVault(); defer { cleanup() }
        try vault.saveTOTP(config, origin: "https://a.fr", username: "ana")
        #expect(try vault.totp(origin: "https://a.fr", username: "ana") == config)
        #expect(try vault.totp(origin: "https://a.fr", username: "bob") == nil)
        #expect(vault.hasTOTP(origin: "https://a.fr", username: "ana") && !vault.hasTOTP(origin: "https://b.fr", username: "ana"))
        #expect(try vault.usernamesWithTOTP(origin: "https://a.fr") == ["ana"])
    }

    @Test func aSecretCopiedOntoAnotherAccountDoesNotOpen() throws {
        let (vault, cleanup) = try makeVault(); defer { cleanup() }
        try vault.saveTOTP(config, origin: "https://a.fr", username: "ana")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HyperBrowserTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        // Même base : on déplace la boîte chiffrée sur un autre compte à la main.
        let db = try AppDatabase(path: url.path)
        let other = CredentialVault(database: db, keys: StaticKeyProvider())
        try other.saveTOTP(config, origin: "https://a.fr", username: "ana")
        try db.dbPool.write { d in try d.execute(sql: "UPDATE totpSecrets SET username = 'mallory'") }
        #expect(throws: VaultError.self) { _ = try other.totp(origin: "https://a.fr", username: "mallory") }
    }

    @Test func replacingAndDeletingKeepThingsConsistent() throws {
        let (vault, cleanup) = try makeVault(); defer { cleanup() }
        try vault.save(origin: "https://a.fr", username: "ana", password: "pw-long-1")
        try vault.saveTOTP(config, origin: "https://a.fr", username: "ana")
        var changed = config; changed.digits = 8
        try vault.saveTOTP(changed, origin: "https://a.fr", username: "ana")
        #expect(try vault.totp(origin: "https://a.fr", username: "ana")?.digits == 8)
        let all = try vault.everything()
        #expect(all.count == 1 && all[0].password == "pw-long-1" && all[0].totp?.digits == 8)
        // Supprimer le compte supprime aussi son secret.
        try vault.delete(id: try vault.allLogins()[0].id)
        #expect(!vault.hasTOTP(origin: "https://a.fr", username: "ana"))
        try vault.saveTOTP(config, origin: "https://z.fr", username: "")
        try vault.deleteTOTP(origin: "https://z.fr", username: "")
        #expect(try vault.totp(origin: "https://z.fr", username: "") == nil)
    }
}
