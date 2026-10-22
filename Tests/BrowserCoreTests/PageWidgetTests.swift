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

@Suite struct WidgetPromptTests {
    @Test func shapeHidesTheContent() {
        #expect(WidgetPolicy.shape("Boîte de réception (3) - nolhan@gmail.com", limit: 80) == "aaaaa aa aaaaaaaaa (0) - aaaaaa@aaaaa.aaa")
        #expect(WidgetPolicy.shape("Réunion 14h", limit: 6) == "aaaaaa")
    }

    private let list: [WidgetPrompt.Candidate] = [.init(selector: ".zA", count: 5, text: "Facture"), .init(selector: "tr.zE", count: 2, text: "Facture", bolds: 2), .init(selector: "body", count: 1, text: "")]

    @Test func modelAnswersBecomeWidgetsOrNothing() {
        func make(_ answer: String) -> PageWidget? { WidgetPrompt.widget(fromModel: answer, host: "mail.google.com", request: "le nombre de messages non lus", candidates: list) }
        let widget = make(#"Voici : {"choix": 2, "type": "nombre"}"#)
        #expect(widget?.source == .count(selector: "tr.zE"))
        #expect(widget?.title == "Messages non lus")
        #expect(widget?.symbol == "envelope")
        #expect(make(#"{"choix": "2", "type": "texte"}"#)?.source == .text(selector: "tr.zE"))        // un numéro écrit en texte
        #expect(make(#"{"type": "titre"}"#)?.source == .titleCount(pattern: WidgetPrompt.titlePattern))
        #expect(make(#"{"type": "aucun"}"#) == nil)
        #expect(make("pas de json") == nil)
        #expect(make(#"{"choix": 9, "type": "nombre"}"#) == nil)         // hors de la liste
        #expect(make(#"{"choix": 0, "type": "nombre"}"#) == nil)
        #expect(make(#"{"choix": 3, "type": "nombre"}"#) == nil)         // « body » : trop large, refusé par la politique
        #expect(make(#"{"Type": "Nombre", "Choix": 1}"#)?.source == .count(selector: ".zA"))   // clés et casse tolérées
    }

    @Test func styleComesFromTheRequestAndTheHost() {
        let agenda = WidgetPolicy.style(forRequest: "le prochain rendez-vous de l'agenda", host: "calendar.google.com")
        #expect(agenda.symbol == "calendar")
        #expect(agenda.title == "Prochain rendez-vous de")
        #expect(WidgetPolicy.style(forRequest: "quelque chose", host: "a.com").symbol == WidgetPolicy.fallbackSymbol)
        #expect(WidgetPolicy.style(forRequest: "x", host: "a.com").hue == WidgetPolicy.style(forRequest: "y", host: "a.com").hue)   // stable pour un site
        #expect(WidgetPolicy.style(forRequest: "le nombre de", host: "a.com").title == "A.com")
    }

    @Test func promptNeverCarriesRawText() {
        let prompt = WidgetPrompt.prompt(request: "non lus", host: "mail.google.com", title: "Boîte (3) - secret@x.com",
                                         candidates: [.init(selector: ".zE", count: 3, text: "Facture EDF 120 euros", bolds: 3)])
        #expect(!prompt.contains("secret") && !prompt.contains("Facture") && !prompt.contains("EDF"))
        #expect(prompt.contains("1. .zE ×3 \"aaaaaaa aaa 000 aaaaa\", 3 en gras"))
    }

    @Test func usableValuesOnly() {
        let count = PageWidget(host: "example.com", title: "X", symbol: "bell", hue: .ocre, source: .count(selector: ".a"))
        #expect(WidgetPolicy.isUsable(count, value: "2"))
        #expect(!WidgetPolicy.isUsable(count, value: "0"))
        #expect(!WidgetPolicy.isUsable(count, value: nil))
        let text = PageWidget(host: "example.com", title: "X", symbol: "bell", hue: .ocre, source: .text(selector: ".a"))
        #expect(WidgetPolicy.isUsable(text, value: "14h"))
        #expect(!WidgetPolicy.isUsable(text, value: "  "))
    }
}
