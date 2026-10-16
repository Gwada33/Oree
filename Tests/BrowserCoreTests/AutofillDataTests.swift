import Foundation
import Testing
@testable import BrowserCore

@Suite("Remplissage automatique : adresses et cartes")
struct AutofillDataTests {
    private func home() -> AddressProfile {
        var a = AddressProfile(label: "Maison")
        a.firstName = "Ana"; a.lastName = "Dupont"; a.email = "ana@exemple.fr"; a.phone = "0612345678"
        a.street = "12 rue des Lilas"; a.street2 = "Bât. B"; a.postalCode = "75011"; a.city = "Paris"; a.country = "France"
        return a
    }

    @Test("une adresse donne les valeurs par nom de champ standard, sans les champs vides")
    func addressTokens() {
        let t = home().tokens
        #expect(t["given-name"] == "Ana" && t["family-name"] == "Dupont" && t["name"] == "Ana Dupont")
        #expect(t["address-line1"] == "12 rue des Lilas" && t["address-line2"] == "Bât. B" && t["street-address"] == "12 rue des Lilas\nBât. B")
        #expect(t["postal-code"] == "75011" && t["address-level2"] == "Paris" && t["country-name"] == "France" && t["tel"] == "0612345678")
        #expect(t["organization"] == nil && t["address-level1"] == nil)
        #expect(home().summary == "12 rue des Lilas, 75011 Paris" && !home().isEmpty && AddressProfile().isEmpty)
    }

    @Test("Luhn : un vrai numéro passe, une faute de frappe non")
    func luhn() {
        #expect(CardTools.isValid("4242 4242 4242 4242") && CardTools.isValid("378282246310005") && CardTools.isValid("5555-5555-5555-4444"))
        #expect(!CardTools.isValid("4242 4242 4242 4241") && !CardTools.isValid("1234") && !CardTools.isValid("abcd efgh ijkl mnop"))
    }

    @Test("marque, masque, regroupement")
    func brands() {
        #expect(CardTools.brand(of: "4242424242424242") == "Visa" && CardTools.brand(of: "5555555555554444") == "Mastercard" && CardTools.brand(of: "378282246310005") == "American Express")
        #expect(CardTools.brand(of: "2221000000000009") == "Mastercard" && CardTools.brand(of: "") == "Carte" && CardTools.brand(of: "9999") == "Carte")
        #expect(CardTools.masked("4242 4242 4242 4242") == "•••• 4242" && CardTools.masked("12") == "••••")
        #expect(CardTools.grouped("4242424242424242") == "4242 4242 4242 4242" && CardTools.grouped("378282246310005") == "3782 822463 10005")
    }

    @Test("date d'expiration : formats courants, valeurs impossibles refusées, carte expirée reconnue")
    func expiry() {
        for text in ["08/27", "8/2027", "0827", "08 - 27", "082027"] { let e = CardTools.parseExpiry(text); #expect(e?.month == 8 && e?.year == 2027, "« \(text) »") }
        #expect(CardTools.parseExpiry("13/27") == nil && CardTools.parseExpiry("00/27") == nil && CardTools.parseExpiry("abc") == nil && CardTools.parseExpiry("1") == nil)
        let now = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 16).date!
        #expect(CardTools.isExpired(month: 9, year: 2026, now: now) && !CardTools.isExpired(month: 10, year: 2026, now: now) && !CardTools.isExpired(month: 1, year: 2027, now: now))
    }

    @Test("une carte donne son numéro nu, son titulaire et sa date sous toutes les formes ; jamais de code de sécurité")
    func cardTokens() {
        var c = CardProfile(label: "Perso"); c.holder = "ANA DUPONT"; c.number = "4242 4242 4242 4242"; c.expMonth = 8; c.expYear = 2027
        let t = c.tokens
        #expect(t["cc-number"] == "4242424242424242" && t["cc-name"] == "ANA DUPONT" && t["cc-exp-month"] == "08" && t["cc-exp-year"] == "2027" && t["cc-exp"] == "08/27")
        #expect(t["cc-csc"] == nil && !t.values.contains { $0.count == 3 && $0.allSatisfy(\.isNumber) })
        #expect(c.summary == "Visa •••• 4242 · 08/27")
    }
}
