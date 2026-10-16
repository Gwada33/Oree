import Testing
import Foundation
import BrowserCore
@testable import BrowserStorage

struct PasswordExportRoundTripTests {
    @Test func whatIsExportedReadsBackWithTheImporter() throws {
        let rows: [PasswordCSVExporter.Row] = [.init(url: "https://a.fr", username: "ana", password: "p,w\"d"), .init(url: "https://b.fr", username: "bob", password: "simple")]
        let result = try PasswordCSVImporter.parse(PasswordCSVExporter.csv(rows))
        #expect(result.entries.map(\.password) == ["p,w\"d", "simple"] && result.entries.map(\.username) == ["ana", "bob"] && result.skipped == 0)
    }

    @Test func theTwoFactorSecretComesBackThroughTheVault() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HyperBrowserTests-\(UUID().uuidString).sqlite"); defer { try? FileManager.default.removeItem(at: url) }
        let vault = CredentialVault(database: try AppDatabase(path: url.path), keys: StaticKeyProvider())
        let csv = PasswordCSVExporter.csv([.init(url: "https://a.fr", username: "ana", password: "pw-long-1", otpAuth: "otpauth://totp/Ex:ana?secret=JBSWY3DPEHPK3PXP&issuer=Ex")])
        let parsed = try PasswordCSVImporter.parse(csv)
        #expect(parsed.entries.first?.otpAuth.hasPrefix("otpauth://totp") == true)
        try vault.importEntries(parsed.entries)
        #expect(try vault.totp(origin: "https://a.fr", username: "ana")?.secret == Base32.decode("JBSWY3DPEHPK3PXP"))
    }
}
