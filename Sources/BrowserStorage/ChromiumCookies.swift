import Foundation
import GRDB
import CommonCrypto
import Security

/// A cookie read from another Chromium browser, decrypted and ready to be handed to WebKit.
public struct ImportedCookie: Sendable, Equatable {
    public let host: String
    public let name: String
    public let value: String
    public let path: String
    /// `nil` = session cookie.
    public let expires: Date?
    public let isSecure: Bool
    public let isHTTPOnly: Bool
    /// "lax" / "strict" / nil.
    public let sameSite: String?
}

public enum ChromiumCookieError: Error, Equatable {
    case databaseNotFound
    case keychainDenied
    case unreadable
    /// macOS refuses access to Brave's data folder (privacy protection).
    case folderNotReadable
}

/// Imports the cookies of the user's own Brave profile (same Mac, same user) — the user asks for it
/// explicitly and macOS shows its own Keychain prompt before the "Brave Safe Storage" key is released.
///
/// Chromium on macOS stores `v10` + AES-128-CBC(ciphertext) per cookie; the key is
/// PBKDF2-SHA1(Keychain password, "saltysalt", 1003 rounds, 16 bytes) and the IV is 16 spaces.
/// Since database version 24 the plaintext starts with the SHA-256 of the host, which is dropped.
/// Cookie values are never logged and never leave this process.
public enum ChromiumCookies {
    public static let braveService = "Brave Safe Storage"
    public static let braveAccount = "Brave"

    public static var braveRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser")
    }

    /// "Default" first, then "Profile 1", "Profile 2"… (people often browse in a non-default profile).
    public static func profileDirectories(root: URL = braveRoot) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let profiles = names.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted { a, b in
            if a == "Default" { return true }
            if b == "Default" { return false }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return profiles.map { root.appendingPathComponent($0) }
    }

    /// Every cookie database found, per profile (newer Chromium keeps the file under Network/).
    public static func braveCookieDatabases(root: URL = braveRoot) -> [URL] {
        profileDirectories(root: root).compactMap { dir in
            ["Network/Cookies", "Cookies"].map { dir.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    public static var braveCookieDatabase: URL? { braveCookieDatabases().first }

    /// Can this process list the folder? macOS blocks other apps' data (Full Disk Access / App Data) with
    /// error 257 until the user allows it or picks the folder in an open panel.
    public static func canRead(_ root: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil
    }

    /// Does this folder look like a Brave user-data folder with at least one cookie database?
    public static func hasCookieDatabase(_ root: URL) -> Bool { !braveCookieDatabases(root: root).isEmpty }

    /// Metadata only (no cookie values, no secrets): why an import might fail on this Mac.
    public static func diagnose() -> [String] {
        var lines: [String] = []
        let root = braveRoot
        lines.append("racine: \(root.path)")
        do {
            let items = try FileManager.default.contentsOfDirectory(atPath: root.path)
            lines.append("dossier lisible: oui (\(items.count) éléments); profils: \(profileDirectories().map(\.lastPathComponent))")
        } catch {
            lines.append("dossier lisible: NON (\((error as NSError).domain) \((error as NSError).code))")
        }
        for dir in profileDirectories() {
            for rel in ["Network/Cookies", "Cookies"] {
                let url = dir.appendingPathComponent(rel)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let readable = FileManager.default.isReadableFile(atPath: url.path)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
                lines.append("\(dir.lastPathComponent)/\(rel): présent, lisible=\(readable), \(size) octets")
            }
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: braveService,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let accounts = (item as? [[String: Any]])?.compactMap { $0[kSecAttrAccount as String] as? String } ?? []
        lines.append("trousseau « \(braveService) »: statut \(status), comptes \(accounts)")
        return lines
    }

    // MARK: Crypto (pure, tested)

    public static func deriveKey(password: String) -> Data {
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count, salt, salt.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        precondition(status == kCCSuccess)
        return Data(key)
    }

    /// Decrypts one `encrypted_value`. Returns nil if it isn't a v10 blob or can't be decrypted.
    public static func decrypt(_ blob: Data, key: Data, stripsHostHash: Bool) -> String? {
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { return nil }
        let cipher = [UInt8](blob.dropFirst(3))
        guard !cipher.isEmpty, cipher.count % kCCBlockSizeAES128 == 0 else { return nil }
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        var written = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             [UInt8](key), key.count, iv, cipher, cipher.count, &out, out.count, &written)
        guard status == kCCSuccess else { return nil }
        var plain = Data(out.prefix(written))
        if stripsHostHash { guard plain.count >= 32 else { return nil }; plain = plain.dropFirst(32) }
        return String(data: plain, encoding: .utf8)
    }

    /// Chromium timestamps count microseconds since 1601-01-01; 0 means "session cookie".
    public static func date(fromChromeTime micros: Int64) -> Date? {
        guard micros > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(micros) / 1_000_000 - 11_644_473_600)
    }

    // MARK: Reading

    /// Reads and decrypts every non-expired cookie of a Chromium `Cookies` database.
    /// The file is copied first: the browser keeps it locked while it runs.
    public static func read(databaseURL: URL, key: Data, now: Date = Date()) throws -> [ImportedCookie] {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("oree-cookies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let copy = temp.appendingPathComponent("Cookies")
        try FileManager.default.copyItem(at: databaseURL, to: copy)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: side.path) { try? FileManager.default.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix)) }
        }

        let queue: DatabaseQueue
        do { queue = try DatabaseQueue(path: copy.path) } catch { throw ChromiumCookieError.unreadable }
        return try queue.read { db in
            let version = (try? Int.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'version'")) ?? 0
            let rows = try Row.fetchAll(db, sql: """
                SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite FROM cookies
                """)
            var result: [ImportedCookie] = []
            for row in rows {
                let expiresMicros: Int64 = row["expires_utc"] ?? 0
                let expires = date(fromChromeTime: expiresMicros)
                if let expires, expires <= now { continue }
                let plain: String? = row["value"]
                let encrypted: Data = row["encrypted_value"] ?? Data()
                let value: String
                if let plain, !plain.isEmpty { value = plain }
                else if let decrypted = decrypt(encrypted, key: key, stripsHostHash: version >= 24) { value = decrypted }
                else { continue }
                let sameSiteRaw: Int = row["samesite"] ?? -1
                result.append(ImportedCookie(
                    host: row["host_key"] ?? "", name: row["name"] ?? "", value: value, path: row["path"] ?? "/",
                    expires: expires, isSecure: (row["is_secure"] ?? 0) != 0, isHTTPOnly: (row["is_httponly"] ?? 0) != 0,
                    sameSite: sameSiteRaw == 2 ? "strict" : sameSiteRaw == 1 ? "lax" : nil))
            }
            return result.filter { !$0.host.isEmpty && !$0.name.isEmpty }
        }
    }

    // MARK: Keychain + entry point

    /// Asks the Keychain for Brave's "Safe Storage" password. macOS shows its own approval dialog
    /// (the item belongs to Brave); if the user refuses, nothing is read.
    public static func keychainPassword() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: braveService,
            kSecAttrAccount as String: braveAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw ChromiumCookieError.keychainDenied
        }
        return password
    }

    /// Reads every non-expired cookie from all of the user's Brave profiles (`root` = the Brave-Browser folder,
    /// possibly picked by the user in an open panel).
    public static func importFromBrave(root: URL = braveRoot) throws -> [ImportedCookie] {
        guard canRead(root) else { throw ChromiumCookieError.folderNotReadable }
        let databases = braveCookieDatabases(root: root)
        guard !databases.isEmpty else { throw ChromiumCookieError.databaseNotFound }
        let key = deriveKey(password: try keychainPassword())
        var all: [ImportedCookie] = []
        var lastError: Error?
        for database in databases {
            do { all += try read(databaseURL: database, key: key) } catch { lastError = error }
        }
        if all.isEmpty, let lastError { throw lastError }
        return all
    }
}
