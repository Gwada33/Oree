import Foundation

/// Une adresse enregistrée pour remplir les formulaires. Gardée chiffrée sur ce Mac (voir `AutofillStore`).
public struct AddressProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var label: String
    public var firstName = "", lastName = "", organization = ""
    public var email = "", phone = ""
    public var street = "", street2 = "", postalCode = "", city = "", region = "", country = ""
    public init(id: UUID = UUID(), label: String = "") { self.id = id; self.label = label }

    public var fullName: String { [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ") }
    /// « 12 rue des Lilas, 75011 Paris » : ce que la personne voit dans le menu.
    public var summary: String {
        let place = [postalCode, city].filter { !$0.isEmpty }.joined(separator: " ")
        return [street, place].filter { !$0.isEmpty }.joined(separator: ", ")
    }
    public var isEmpty: Bool { [firstName, lastName, organization, email, phone, street, street2, postalCode, city, region, country].allSatisfy { $0.isEmpty } }

    /// Les valeurs par nom de champ standard (`autocomplete` du HTML) : la page sait quel champ prend quoi, l'app donne tout ce qu'elle a.
    public var tokens: [String: String] {
        let all: [String: String] = [
            "name": fullName, "given-name": firstName, "family-name": lastName, "organization": organization,
            "email": email, "tel": phone, "tel-national": phone,
            "street-address": [street, street2].filter { !$0.isEmpty }.joined(separator: "\n"), "address-line1": street, "address-line2": street2,
            "postal-code": postalCode, "address-level2": city, "address-level1": region, "country-name": country, "country": country,
        ]
        return all.filter { !$0.value.isEmpty }
    }
}

/// Une carte bancaire. Le code de sécurité (CVC) n'est JAMAIS gardé : la personne le tape à chaque achat.
public struct CardProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var label: String
    public var holder = ""
    public var number = ""
    public var expMonth = 0
    public var expYear = 0          // quatre chiffres
    public init(id: UUID = UUID(), label: String = "") { self.id = id; self.label = label }

    public var brand: String { CardTools.brand(of: number) }
    public var masked: String { CardTools.masked(number) }
    public var summary: String { "\(brand) \(masked)" + (expMonth > 0 ? " · \(String(format: "%02d", expMonth))/\(String(expYear % 100).paddedTwo)" : "") }

    public var tokens: [String: String] {
        var all: [String: String] = ["cc-name": holder, "cc-number": CardTools.digits(number)]
        if expMonth > 0, expYear > 0 {
            all["cc-exp-month"] = String(format: "%02d", expMonth)
            all["cc-exp-year"] = String(expYear)
            all["cc-exp"] = String(format: "%02d/%@", expMonth, String(expYear % 100).paddedTwo)
        }
        return all.filter { !$0.value.isEmpty }
    }
}

private extension String { var paddedTwo: String { count < 2 ? "0" + self : self } }

public enum CardTools {
    public static func digits(_ text: String) -> String { text.filter(\.isNumber) }

    /// Contrôle de Luhn : détecte une faute de frappe dans un numéro de carte.
    public static func isValid(_ number: String) -> Bool {
        let d = digits(number).compactMap { Int(String($0)) }
        guard (12...19).contains(d.count) else { return false }
        var sum = 0
        for (i, v) in d.reversed().enumerated() { var x = v; if i % 2 == 1 { x *= 2; if x > 9 { x -= 9 } }; sum += x }
        return sum % 10 == 0
    }

    public static func brand(of number: String) -> String {
        let d = digits(number)
        guard let first = d.first else { return "Carte" }
        let two = Int(d.prefix(2)) ?? 0, four = Int(d.prefix(4)) ?? 0
        if first == "4" { return "Visa" }
        if (51...55).contains(two) || (2221...2720).contains(four) { return "Mastercard" }
        if two == 34 || two == 37 { return "American Express" }
        if d.hasPrefix("6011") || d.hasPrefix("65") || (644...649).contains(Int(d.prefix(3)) ?? 0) { return "Discover" }
        if (3528...3589).contains(four) { return "JCB" }
        return "Carte"
    }

    /// « •••• 1234 ».
    public static func masked(_ number: String) -> String {
        let d = digits(number)
        return d.count >= 4 ? "•••• " + d.suffix(4) : "••••"
    }

    /// « 4242424242424242 » → « 4242 4242 4242 4242 » (Amex : 4-6-5).
    public static func grouped(_ number: String) -> String {
        let d = digits(number)
        let sizes = d.hasPrefix("34") || d.hasPrefix("37") ? [4, 6, 5] : Array(repeating: 4, count: 5)
        var out: [String] = [], index = d.startIndex
        for size in sizes where index < d.endIndex {
            let end = d.index(index, offsetBy: size, limitedBy: d.endIndex) ?? d.endIndex
            out.append(String(d[index..<end])); index = end
        }
        return out.joined(separator: " ")
    }

    /// « 08/27 », « 8/2027 », « 0827 » → (8, 2027). nil si illisible ou impossible.
    public static func parseExpiry(_ text: String) -> (month: Int, year: Int)? {
        let parts = text.split(whereSeparator: { !$0.isNumber }).map(String.init)
        var month = 0, year = 0
        if parts.count == 2 { month = Int(parts[0]) ?? 0; year = Int(parts[1]) ?? 0 }
        else if parts.count == 1, parts[0].count == 4 || parts[0].count == 6 {
            month = Int(parts[0].prefix(2)) ?? 0; year = Int(parts[0].dropFirst(2)) ?? 0
        } else { return nil }
        if year < 100 { year += 2000 }
        guard (1...12).contains(month), (2000...2200).contains(year) else { return nil }
        return (month, year)
    }

    public static func isExpired(month: Int, year: Int, now: Date = Date()) -> Bool {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: now)
        return year < (c.year ?? 0) || (year == c.year && month < (c.month ?? 0))
    }
}
