import Testing
import Foundation
@testable import BrowserStorage

struct PasswordCSVImporterTests {
    @Test func parsesApplePasswordsExport() throws {
        let csv = #"""
        Title,URL,Username,Password,Notes,OTPAuth
        GitHub,https://github.com/login,octo,p@ss,,
        Example,example.com,me@x.fr,"pw,with ""quotes""",note,otpauth://totp/x
        """#
        let result = try PasswordCSVImporter.parse(csv)
        #expect(result.entries == [
            .init(origin: "https://github.com", username: "octo", password: "p@ss"),
            .init(origin: "https://example.com", username: "me@x.fr", password: "pw,with \"quotes\""),
        ])
        #expect(result.skipped == 0)
    }

    @Test func parsesChromeStyleHeadersAndCRLF() throws {
        let csv = "name,url,username,password\r\nA,https://a.com/x,u,p\r\n"
        let result = try PasswordCSVImporter.parse(csv)
        #expect(result.entries.count == 1)
        #expect(result.entries[0].origin == "https://a.com")
    }

    @Test func multilineQuotedFieldsStayInOneRow() throws {
        let csv = "Title,URL,Username,Password,Notes\nA,https://a.com,u,p,\"line1\nline2\"\nB,https://b.com,v,q,\n"
        let result = try PasswordCSVImporter.parse(csv)
        #expect(result.entries.map(\.origin) == ["https://a.com", "https://b.com"])
    }

    @Test func insecureAndIncompleteRowsAreSkipped() throws {
        let csv = """
        URL,Username,Password
        http://plain.example.com,u,p
        https://ok.com,u,
        ,u,p
        http://localhost:3000/login,dev,pw
        """
        let result = try PasswordCSVImporter.parse(csv)
        #expect(result.entries.map(\.origin) == ["http://localhost:3000"])
        #expect(result.skipped == 3)
    }

    @Test func fileWithoutPasswordColumnIsRejected() {
        #expect(throws: PasswordCSVImporter.ImportError.missingColumns) {
            try PasswordCSVImporter.parse("a,b\n1,2\n")
        }
    }

    @Test func importedEntriesLandEncryptedInTheVault() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HyperBrowserTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let vault = CredentialVault(database: try AppDatabase(path: url.path), keys: StaticKeyProvider())
        let result = try PasswordCSVImporter.parse("URL,Username,Password\nhttps://a.com,me,secret\n")
        #expect(try vault.importEntries(result.entries) == 1)
        #expect(try vault.password(origin: "https://a.com", username: "me") == "secret")
    }
}
