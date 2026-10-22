import Testing
import Foundation
@testable import BrowserCore

@Suite struct PageWidgetTests {
    @Test func gmailTitleGivesTheUnreadCount() {
        guard case .titleCount(let pattern) = WidgetPolicy.gmail.source else { Issue.record("source"); return }
        #expect(WidgetPolicy.capture(in: "Boîte de réception (3) - nolhan@gmail.com - Gmail", pattern: pattern) == "3")
        #expect(WidgetPolicy.capture(in: "Boîte de réception - nolhan@gmail.com - Gmail", pattern: pattern) == nil)
    }

    @Test func displayCapsNumbersAndText() {
        #expect(WidgetPolicy.display("7") == "7")
        #expect(WidgetPolicy.display("1500") == "99+")
        #expect(WidgetPolicy.display("  prochain   rdv 14h ") == "prochain rdv …")
        #expect(WidgetPolicy.display("   ") == nil)
        #expect(WidgetPolicy.display(nil) == nil)
    }

    @Test func validationRefusesUnsafeOrBrokenWidgets() {
        func make(_ source: PageWidget.Source, host: String = "example.com", title: String = "Ex", symbol: String = "bell") -> PageWidget {
            PageWidget(host: host, title: title, symbol: symbol, hue: .ocre, source: source)
        }
        #expect(WidgetPolicy.validated(make(.count(selector: ".unread-badge"))) != nil)
        #expect(WidgetPolicy.validated(make(.count(selector: "body"))) == nil)
        #expect(WidgetPolicy.validated(make(.text(selector: "x } body { display:none"))) == nil)
        #expect(WidgetPolicy.validated(make(.titleCount(pattern: "("))) == nil)             // ne compile pas
        #expect(WidgetPolicy.validated(make(.titleCount(pattern: #"\d+"#))) == nil)         // pas de groupe capturé
        #expect(WidgetPolicy.validated(make(.titleCount(pattern: #"\((\d+)\)"#), host: "localhost")) == nil)
        #expect(WidgetPolicy.validated(make(.titleCount(pattern: #"\((\d+)\)"#), title: "  ")) == nil)
        #expect(WidgetPolicy.validated(make(.titleCount(pattern: #"\((\d+)\)"#), symbol: "not.a.symbol"))?.symbol == WidgetPolicy.fallbackSymbol)
        #expect(WidgetPolicy.validated(make(.titleCount(pattern: #"\((\d+)\)"#), host: "WWW.Example.com"))?.host == "example.com")
    }

    @Test func hostMatchingIncludesSubdomains() {
        #expect(WidgetPolicy.matches(pageHost: "mail.google.com", widgetHost: "mail.google.com"))
        #expect(WidgetPolicy.matches(pageHost: "m.mail.google.com", widgetHost: "mail.google.com"))
        #expect(!WidgetPolicy.matches(pageHost: "evilmail.google.com", widgetHost: "mail.google.com"))
        #expect(!WidgetPolicy.matches(pageHost: nil, widgetHost: "mail.google.com"))
    }

    @Test func everyBuiltInWidgetIsValid() {
        for widget in WidgetPolicy.builtIn { #expect(WidgetPolicy.validated(widget) != nil) }
    }
}
