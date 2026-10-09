import Testing
import Foundation
import GRDB
import CommonCrypto
@testable import BrowserStorage

struct ChromiumCookiesTests {
    /// Encrypts like Chromium does (used only to build test fixtures).
    private func encrypt(_ text: String, key: Data, prependHostHash: Bool) -> Data {
        var plain = Data()
        if prependHostHash { plain.append(Data(repeating: 0xAB, count: 32)) }
        plain.append(Data(text.utf8))
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
        var written = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             [UInt8](key), key.count, iv, [UInt8](plain), plain.count, &out, out.count, &written)
        #expect(status == kCCSuccess)
        return Data("v10".utf8) + Data(out.prefix(written))
    }

    @Test func keyDerivationIsStable() {
        let key = ChromiumCookies.deriveKey(password: "peanuts")
        #expect(key.count == 16)
        #expect(key == ChromiumCookies.deriveKey(password: "peanuts"))
        #expect(key != ChromiumCookies.deriveKey(password: "other"))
    }

    @Test func decryptRoundTripWithAndWithoutHostHash() {
        let key = ChromiumCookies.deriveKey(password: "pw")
        #expect(ChromiumCookies.decrypt(encrypt("secret-value", key: key, prependHostHash: false), key: key, stripsHostHash: false) == "secret-value")
        #expect(ChromiumCookies.decrypt(encrypt("secret-value", key: key, prependHostHash: true), key: key, stripsHostHash: true) == "secret-value")
    }

    @Test func decryptRejectsGarbage() {
        let key = ChromiumCookies.deriveKey(password: "pw")
        #expect(ChromiumCookies.decrypt(Data("v11abc".utf8), key: key, stripsHostHash: false) == nil)
        #expect(ChromiumCookies.decrypt(Data("v10".utf8) + Data(repeating: 1, count: 5), key: key, stripsHostHash: false) == nil)
        let wrong = ChromiumCookies.deriveKey(password: "wrong")
        #expect(ChromiumCookies.decrypt(encrypt("x", key: key, prependHostHash: false), key: wrong, stripsHostHash: false) != "x")
    }

    @Test func chromeTimeConversion() {
        #expect(ChromiumCookies.date(fromChromeTime: 0) == nil)
        // 2020-01-01T00:00:00Z = 13_222_310_400 s since 1601
        #expect(ChromiumCookies.date(fromChromeTime: 13_222_310_400 * 1_000_000) == Date(timeIntervalSince1970: 1_577_836_800))
    }

    @Test func readsDecryptsAndSkipsExpired() throws {
        let key = ChromiumCookies.deriveKey(password: "pw")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cookies-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = try DatabaseQueue(path: url.path)
        let future = Int64((Date().timeIntervalSince1970 + 86_400 + 11_644_473_600) * 1_000_000)
        let past = Int64((Date().timeIntervalSince1970 - 86_400 + 11_644_473_600) * 1_000_000)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE meta (key TEXT, value TEXT)")
            try db.execute(sql: "INSERT INTO meta VALUES ('version', '24')")
            try db.execute(sql: """
                CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT,
                                      expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, samesite INTEGER)
                """)
            let rows: [(String, String, String, Data, Int64, Int, Int, Int)] = [
                (".a.example", "sid", "", encrypt("tok", key: key, prependHostHash: true), future, 1, 1, 1),
                (".b.example", "old", "", encrypt("gone", key: key, prependHostHash: true), past, 0, 0, -1),
                (".c.example", "plain", "visible", Data(), 0, 0, 0, 2),
            ]
            for r in rows {
                try db.execute(sql: "INSERT INTO cookies VALUES (?,?,?,?,?,?,?,?,?)",
                               arguments: [r.0, r.1, r.2, r.3, "/", r.4, r.5, r.6, r.7])
            }
        }
        let cookies = try ChromiumCookies.read(databaseURL: url, key: key)
        #expect(cookies.count == 2)
        let sid = try #require(cookies.first { $0.name == "sid" })
        #expect(sid.value == "tok" && sid.isSecure && sid.isHTTPOnly && sid.expires != nil && sid.sameSite == "lax")
        let plain = try #require(cookies.first { $0.name == "plain" })
        #expect(plain.value == "visible" && plain.expires == nil && plain.sameSite == "strict")
        #expect(!cookies.contains { $0.name == "old" })
    }
}
