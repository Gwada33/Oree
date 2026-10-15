import Testing
import Foundation
@testable import BrowserCore

@Suite struct SiteInfoPolicyTests {
    private func origin(_ s: String) -> String? { SiteInfoPolicy.origin(for: URL(string: s)) }

    @Test func originsMatchTheKeyPermissionsAreStoredUnder() {
        #expect(origin("https://Example.com/a?b=1") == "https://example.com")
        #expect(origin("https://example.com:443/x") == "https://example.com")
        #expect(origin("http://localhost:3000/") == "http://localhost:3000")
        #expect(origin("oree://home") == nil)
        #expect(origin("file:///tmp/a") == nil)
        #expect(SiteInfoPolicy.origin(for: nil) == nil)
    }

    @Test func connectionStatusIsHonest() {
        #expect(SiteInfoPolicy.connection(for: URL(string: "https://a.example")).secure)
        #expect(!SiteInfoPolicy.connection(for: URL(string: "http://a.example")).secure)
        #expect(SiteInfoPolicy.connection(for: URL(string: "http://a.example")).title == "Connexion non sécurisée")
        #expect(!SiteInfoPolicy.connection(for: URL(string: "file:///x")).secure)
        #expect(SiteInfoPolicy.connection(for: URL(string: "oree://home")).title == "Page d’Orée")
    }

    @Test func validityIsDescribedInDays() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func after(_ days: Int) -> Date { cal.date(byAdding: .day, value: days, to: now)! }
        #expect(SiteInfoPolicy.validity(until: after(45), now: now, calendar: cal) == "Valable encore 45 jours")
        #expect(SiteInfoPolicy.validity(until: after(1), now: now, calendar: cal) == "Valable jusqu’à demain")
        #expect(SiteInfoPolicy.validity(until: after(0), now: now, calendar: cal) == "Expire aujourd’hui")
        #expect(SiteInfoPolicy.validity(until: after(-1), now: now, calendar: cal) == "Expiré depuis 1 jour")
        #expect(SiteInfoPolicy.validity(until: after(-3), now: now, calendar: cal) == "Expiré depuis 3 jours")
    }

    @Test func cookieDomainsAreMatchedBySuffixOnly() {
        #expect(SiteInfoPolicy.cookieDomain(".example.com", belongsTo: "www.example.com"))
        #expect(SiteInfoPolicy.cookieDomain("example.com", belongsTo: "example.com"))
        #expect(!SiteInfoPolicy.cookieDomain("example.com", belongsTo: "notexample.com"))
        #expect(!SiteInfoPolicy.cookieDomain("sub.example.com", belongsTo: "example.com"))
    }
}
