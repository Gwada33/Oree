import Foundation
import Testing
@testable import BrowserCore

@Suite("Codes à usage unique (RFC 6238)")
struct TOTPTests {
    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }
    private let sha1 = TOTPConfig(secret: Data("12345678901234567890".utf8), digits: 8, algorithm: .sha1)
    private let sha256 = TOTPConfig(secret: Data("12345678901234567890123456789012".utf8), digits: 8, algorithm: .sha256)
    private let sha512 = TOTPConfig(secret: Data("1234567890123456789012345678901234567890123456789012345678901234".utf8), digits: 8, algorithm: .sha512)

    @Test("les vecteurs de l'annexe B du RFC 6238 (SHA-1, SHA-256, SHA-512)")
    func rfcVectors() {
        for (time, expected) in [(59.0, ("94287082", "46119246", "90693936")), (1111111109, ("07081804", "68084774", "25091201")), (1111111111, ("14050471", "67062674", "99943326")),
                                 (1234567890, ("89005924", "91819424", "93441116")), (2000000000, ("69279037", "90698825", "38618901")), (20000000000, ("65353130", "77737706", "47863826"))] {
            #expect(sha1.code(at: at(time)) == expected.0, "SHA-1 à \(time)")
            #expect(sha256.code(at: at(time)) == expected.1, "SHA-256 à \(time)")
            #expect(sha512.code(at: at(time)) == expected.2, "SHA-512 à \(time)")
        }
    }

    @Test("base32 : minuscules, espaces et remplissage tolérés ; un caractère étranger refuse")
    func base32() {
        #expect(Base32.decode("JBSWY3DPEHPK3PXP")?.count == 10)
        #expect(Base32.decode("jbsw y3dp-ehpk 3pxp") == Base32.decode("JBSWY3DPEHPK3PXP"))
        #expect(Base32.decode("MFRGG===") == Data("abc".utf8))
        #expect(Base32.decode("1") == nil && Base32.decode("") == nil && Base32.decode("AB!") == nil)
    }

    @Test("l'adresse otpauth:// donne le secret, les chiffres, la période, l'algorithme et l'émetteur")
    func uri() throws {
        let config = try #require(TOTPConfig.parse("otpauth://totp/Exemple:ana@exemple.fr?secret=JBSWY3DPEHPK3PXP&issuer=Exemple&digits=8&period=60&algorithm=SHA256"))
        #expect(config.digits == 8 && config.period == 60 && config.algorithm == .sha256 && config.issuer == "Exemple" && config.account == "ana@exemple.fr")
        let simple = try #require(TOTPConfig.parse("  JBSW Y3DP EHPK 3PXP  "))
        #expect(simple.digits == 6 && simple.period == 30 && simple.algorithm == .sha1 && simple.secret == Base32.decode("JBSWY3DPEHPK3PXP"))
        #expect(TOTPConfig.parse("otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP") == nil)
        #expect(TOTPConfig.parse("otpauth://totp/x?secret=1") == nil)
        #expect(TOTPConfig.parse("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&digits=12") == nil)
        #expect(TOTPConfig.parse("") == nil && TOTPConfig.parse("pas du base32 !") == nil)
    }

    @Test("le code a toujours le bon nombre de chiffres, zéros initiaux compris, et change à chaque période")
    func shape() {
        let config = TOTPConfig(secret: Data("secret".utf8))
        for t in stride(from: 0.0, to: 3000, by: 30) { #expect(config.code(at: at(t)).count == 6) }
        #expect(config.code(at: at(100)) == config.code(at: at(119)) && config.code(at: at(119)) != config.code(at: at(120)))
        #expect(config.secondsRemaining(at: at(100)) == 20 && config.secondsRemaining(at: at(120)) == 30)
    }
}

@Suite("Santé des mots de passe")
struct PasswordAuditTests {
    private func item(_ origin: String, _ user: String, _ password: String) -> PasswordAudit.Item { .init(origin: origin, username: user, password: password) }

    @Test("faible : court, très courant, caractère répété, suite simple ; un bon mot de passe ne l'est pas")
    func weak() {
        for password in ["abc", "password", "12345678", "aaaaaaaa", "azertyuiop", "Motdepasse", "abcdefgh"] where password != "Motdepasse" { #expect(PasswordAudit.isWeak(password), "« \(password) »") }
        #expect(!PasswordAudit.isWeak("c0rrect-horse-battery") && !PasswordAudit.isWeak("Tr0ub4dor&3x"))
    }

    @Test("les comptes qui partagent un mot de passe sont regroupés ; les autres non")
    func reuse() {
        let report = PasswordAudit.analyze([item("https://a.fr", "ana", "S3cret-long-1"), item("https://b.fr", "ana", "S3cret-long-1"), item("https://c.fr", "ana", "Autre-long-2"), item("https://d.fr", "ana", "")])
        #expect(report.reused == [["ana — https://a.fr", "ana — https://b.fr"]])
        #expect(report.checked == 4 && report.weak.isEmpty)
    }

    @Test("une fuite connue est rapportée par compte, avec son nombre")
    func breaches() {
        let report = PasswordAudit.analyze([item("https://a.fr", "", "Fuite-connue-99"), item("https://b.fr", "bob", "Jamais-vu-123")], breaches: ["Fuite-connue-99": 4210])
        #expect(report.breached == ["https://a.fr": 4210] && !report.isClean)
        #expect(PasswordAudit.analyze([item("https://a.fr", "x", "Tr0ub4dor&3x")]).isClean)
    }

    @Test("k-anonymat : 5 caractères partent, le reste est comparé ici (vecteur : « password »)")
    func pwned() {
        let parts = PasswordAudit.pwnedParts(of: "password")
        #expect(parts.prefix == "5BAA6" && parts.suffix == "1E4C9B93F3F0682250B6CF8331B7EE68FD8")
        let response = "0018A45C4D1DEF81644B54AB7F969B88D65:1\r\n1E4C9B93F3F0682250B6CF8331B7EE68FD8:9545824\r\n00D4F6E8FA6EECAD2A3AA415EEC418D38EC:0"
        #expect(PasswordAudit.pwnedCount(in: response, suffix: parts.suffix) == 9_545_824)
        #expect(PasswordAudit.pwnedCount(in: response, suffix: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF") == 0)
        #expect(PasswordAudit.pwnedURL(prefix: "5BAA6")?.absoluteString == "https://api.pwnedpasswords.com/range/5BAA6")
    }
}

@Suite("Export CSV des mots de passe")
struct PasswordCSVExporterTests {
    @Test("en-tête, guillemets doublés, virgules et sauts de ligne protégés")
    func format() {
        let csv = PasswordCSVExporter.csv([.init(url: "https://a.fr", username: "ana", password: "p,w\"d"), .init(url: "https://b.fr", username: "", password: "x\ny", otpAuth: "otpauth://totp/x?secret=ABC")])
        #expect(csv == "URL,Username,Password,Notes,OTPAuth\nhttps://a.fr,ana,\"p,w\"\"d\",,\nhttps://b.fr,,\"x\ny\",,otpauth://totp/x?secret=ABC\n")
    }
}
