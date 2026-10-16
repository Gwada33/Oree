import Foundation
import CryptoKit

/// Codes à usage unique (RFC 6238) : le code à 6 chiffres que changent les applications d'authentification toutes les 30 secondes.
/// Calculé en local à partir d'un secret que la personne a enregistré ; rien n'est envoyé nulle part.
public enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// Espaces, tirets et « = » de remplissage ignorés ; minuscules acceptées. nil si un caractère n'est pas du base32.
    public static func decode(_ text: String) -> Data? {
        let cleaned = text.uppercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "=" }
        guard !cleaned.isEmpty else { return nil }
        var buffer = 0, bits = 0
        var out = Data()
        for c in cleaned {
            guard let value = alphabet.firstIndex(of: c) else { return nil }
            buffer = (buffer << 5) | value; bits += 5
            if bits >= 8 { bits -= 8; out.append(UInt8((buffer >> bits) & 0xff)) }
        }
        return out.isEmpty ? nil : out
    }
}

public struct TOTPConfig: Equatable, Sendable, Codable {
    public enum Algorithm: String, Sendable, Codable { case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512" }
    public var secret: Data
    public var digits: Int
    public var period: Int
    public var algorithm: Algorithm
    public var issuer: String?
    public var account: String?

    public init(secret: Data, digits: Int = 6, period: Int = 30, algorithm: Algorithm = .sha1, issuer: String? = nil, account: String? = nil) {
        self.secret = secret; self.digits = digits; self.period = period; self.algorithm = algorithm; self.issuer = issuer; self.account = account
    }

    /// Ce que la personne colle : une adresse `otpauth://totp/…?secret=…` ou le secret seul (« JBSW Y3DP EHPK 3PXP »).
    public static func parse(_ input: String) -> TOTPConfig? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.lowercased().hasPrefix("otpauth://") else { return Base32.decode(text).map { TOTPConfig(secret: $0) } }
        guard let url = URLComponents(string: text), url.host?.lowercased() == "totp" else { return nil }
        func item(_ name: String) -> String? { url.queryItems?.first { $0.name.lowercased() == name }?.value }
        guard let raw = item("secret"), let secret = Base32.decode(raw) else { return nil }
        let digits = Int(item("digits") ?? "") ?? 6, period = Int(item("period") ?? "") ?? 30
        guard (6...8).contains(digits), (10...120).contains(period) else { return nil }
        let algorithm = Algorithm(rawValue: (item("algorithm") ?? "SHA1").uppercased()) ?? .sha1
        let label = url.path.removingPercentEncoding?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let parts = label.split(separator: ":", maxSplits: 1).map(String.init)
        return TOTPConfig(secret: secret, digits: digits, period: period, algorithm: algorithm, issuer: item("issuer") ?? (parts.count == 2 ? parts[0] : nil), account: parts.last)
    }

    /// Le code à l'instant `date`.
    public func code(at date: Date = Date()) -> String {
        let counter = UInt64(max(0, floor(date.timeIntervalSince1970 / Double(period))))
        var big = counter.bigEndian
        let message = Data(bytes: &big, count: 8)
        let key = SymmetricKey(data: secret)
        let mac: Data
        switch algorithm {
        case .sha1: mac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: mac = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: mac = Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let value = (UInt32(mac[offset] & 0x7f) << 24) | (UInt32(mac[offset + 1]) << 16) | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        return String(format: "%0\(digits)d", value % modulus)
    }

    /// Secondes avant le prochain changement de code.
    public func secondsRemaining(at date: Date = Date()) -> Int {
        period - Int(date.timeIntervalSince1970) % period
    }
}
