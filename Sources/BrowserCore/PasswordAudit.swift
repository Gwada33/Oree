import Foundation
import CryptoKit

/// Contrôles de santé des mots de passe enregistrés. Tout se calcule en local, sauf la vérification des fuites, qui n'envoie que les 5 premiers caractères de l'empreinte SHA-1
/// de chaque mot de passe (k-anonymat, service « Pwned Passwords ») : le mot de passe, lui, ne quitte jamais ce Mac.
public enum PasswordAudit {
    public struct Item: Equatable, Sendable {
        public var origin: String, username: String, password: String
        public init(origin: String, username: String, password: String) { self.origin = origin; self.username = username; self.password = password }
    }

    public struct Report: Equatable, Sendable {
        /// Groupes de comptes qui partagent le même mot de passe (2 comptes ou plus).
        public var reused: [[String]]
        public var weak: [String]
        public var breached: [String: Int]            // compte → nombre de fois vu dans des fuites
        public var checked: Int
        public var isClean: Bool { reused.isEmpty && weak.isEmpty && breached.isEmpty }
    }

    static func label(_ item: Item) -> String { item.username.isEmpty ? item.origin : "\(item.username) — \(item.origin)" }

    static let common: Set<String> = ["password", "123456", "12345678", "123456789", "qwerty", "azerty", "motdepasse", "abc123", "111111", "000000", "iloveyou", "admin", "letmein", "welcome", "passw0rd", "azertyuiop", "1234567890"]

    /// Faible : moins de 8 caractères, un mot de passe très courant, un seul caractère répété, ou une suite simple.
    public static func isWeak(_ password: String) -> Bool {
        let lower = password.lowercased()
        guard lower.count >= 8, !common.contains(lower), Set(lower).count > 2 else { return true }
        let sequences = ["abcdefghijklmnopqrstuvwxyz", "0123456789", "azertyuiop", "qwertyuiop"]
        return sequences.contains { $0.contains(lower) }
    }

    /// - Parameter breaches: pour chaque mot de passe (tel quel), combien de fois il figure dans des fuites (absent = jamais vu ou non vérifié).
    public static func analyze(_ items: [Item], breaches: [String: Int] = [:]) -> Report {
        let byPassword = Dictionary(grouping: items.filter { !$0.password.isEmpty }, by: \.password)
        let reused = byPassword.values.filter { $0.count > 1 }.map { $0.map(label).sorted() }.sorted { $0.first ?? "" < $1.first ?? "" }
        let weak = items.filter { !$0.password.isEmpty && isWeak($0.password) }.map(label).sorted()
        var breached: [String: Int] = [:]
        for item in items { if let n = breaches[item.password], n > 0 { breached[label(item)] = n } }
        return Report(reused: reused, weak: weak, breached: breached, checked: items.count)
    }

    // MARK: Pwned Passwords (k-anonymat)

    /// Les deux moitiés de l'empreinte SHA-1 en majuscules : 5 caractères envoyés, le reste gardé ici.
    public static func pwnedParts(of password: String) -> (prefix: String, suffix: String) {
        let hex = Insecure.SHA1.hash(data: Data(password.utf8)).map { String(format: "%02X", $0) }.joined()
        return (String(hex.prefix(5)), String(hex.dropFirst(5)))
    }

    /// La réponse du service (« SUFFIXE:NOMBRE », une ligne par empreinte) : combien de fois ce mot de passe a été vu. Les lignes à 0 sont du remplissage.
    public static func pwnedCount(in response: String, suffix: String) -> Int {
        for line in response.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":")
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).uppercased() == suffix { return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0 }
        }
        return 0
    }

    public static func pwnedURL(prefix: String) -> URL? { URL(string: "https://api.pwnedpasswords.com/range/\(prefix)") }
}

/// Le CSV que l'on peut réimporter ailleurs (Mots de passe d'Apple, Chrome, Firefox…) : en-tête `URL,Username,Password,Notes,OTPAuth`, guillemets doublés, champs avec virgule ou saut de ligne entre guillemets.
public enum PasswordCSVExporter {
    public struct Row: Equatable, Sendable {
        public var url: String, username: String, password: String, otpAuth: String
        public init(url: String, username: String, password: String, otpAuth: String = "") { self.url = url; self.username = username; self.password = password; self.otpAuth = otpAuth }
    }

    static func field(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func csv(_ rows: [Row]) -> String {
        (["URL,Username,Password,Notes,OTPAuth"] + rows.map { [$0.url, $0.username, $0.password, "", $0.otpAuth].map(field).joined(separator: ",") }).joined(separator: "\n") + "\n"
    }
}
