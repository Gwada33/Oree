import Foundation
import Testing
@testable import BrowserCore

@Suite("Registre des actions d'une tâche")
struct ActionLedgerTests {
    private func call(_ name: String, _ json: String = "{}") -> AgentCall { AgentCall(name: name, argumentsJSON: json) }
    private func ok(_ text: String = "ok") -> AgentToolResult { AgentToolResult(ok: true, text: text) }
    private func ko(_ text: String = "non") -> AgentToolResult { AgentToolResult(ok: false, text: text) }

    private func ran(_ ledger: inout ActionLedger, _ c: AgentCall, step: Int, page: String = "p1", result: AgentToolResult) {
        let i = ledger.begin(c, step: step, page: page); ledger.finish(i, result: result)
    }

    @Test("la même demande écrite autrement a la même clé")
    func keys() {
        #expect(ActionLedger.key(for: call("search_web", "{\"query\":\"Météo  Lyon, aujourd'hui !\"}")) == ActionLedger.key(for: call("search_web", "{\"query\":\"meteo lyon aujourd hui\"}")))
        #expect(ActionLedger.key(for: call("open_url", "{\"url\":\"https://www.Example.com/a/#x\"}")) == ActionLedger.key(for: call("open_url", "{\"url\":\"https://example.com/a\"}")))
        #expect(ActionLedger.key(for: call("click", "{\"ref\":\"@e3\"}")) != ActionLedger.key(for: call("click", "{\"ref\":\"@e4\"}")))
        #expect(ActionLedger.key(for: call("type", "{\"text\":\"a\",\"ref\":\"@e1\"}")) == ActionLedger.key(for: call("type", "{\"ref\":\"@e1\",\"text\":\"a\"}")))
    }

    @Test("une recherche déjà faite n'est pas refaite : son résultat est réutilisé")
    func reuseSearch() {
        var ledger = ActionLedger()
        ran(&ledger, call("search_web", "{\"query\":\"météo lyon\"}"), step: 1, result: ok("1. Météo-France"))
        guard case .reuse(let result, let step) = ledger.check(call("search_web", "{\"query\":\"Météo Lyon\"}"), page: "p2") else { Issue.record("à réutiliser"); return }
        #expect(result.text == "1. Météo-France" && step == 1)
    }

    @Test("une lecture de page n'est réutilisée que si la page n'a pas changé")
    func reuseRead() {
        var ledger = ActionLedger()
        ran(&ledger, call("read_page"), step: 1, page: "A", result: ok("texte A"))
        if case .reuse = ledger.check(call("read_page"), page: "A") {} else { Issue.record("même page : réutilisée") }
        #expect(ledger.check(call("read_page"), page: "B") == .run)
    }

    @Test("une action refaite sur la même page est refusée ; sur une page changée, permise")
    func doubleAction() {
        var ledger = ActionLedger()
        ran(&ledger, call("click", "{\"ref\":\"@e5\"}"), step: 1, page: "A", result: ok("Clic"))
        if case .refuse(let why) = ledger.check(call("click", "{\"ref\":\"@e5\"}"), page: "A") { #expect(why.contains("étape 1")) } else { Issue.record("double clic à refuser") }
        #expect(ledger.check(call("click", "{\"ref\":\"@e5\"}"), page: "B") == .run)          // « page suivante » : même bouton, autre page
        #expect(ledger.check(call("click", "{\"ref\":\"@e6\"}"), page: "A") == .run)           // un autre élément
    }

    @Test("une action demandée mais pas vérifiée n'est pas réussie ; en cours, elle ne se double pas")
    func notDoneUntilVerified() {
        var ledger = ActionLedger()
        let c = call("click", "{\"ref\":\"@e1\"}")
        let i = ledger.begin(c, step: 1, page: "A")
        #expect(ledger.entries[i].state == .running)
        if case .refuse(let why) = ledger.check(c, page: "A") { #expect(why.contains("en cours")) } else { Issue.record("déjà en cours") }
        ledger.finish(i, result: ko("Élément introuvable"))
        #expect(ledger.entries[i].state == .failed(1))
        #expect(ledger.check(c, page: "A") == .run)                                            // une reprise reste possible
    }

    @Test("un appel qui échoue deux fois est abandonné")
    func failures() {
        var ledger = ActionLedger()
        let c = call("open_url", "{\"url\":\"https://x.example/\"}")
        ran(&ledger, c, step: 1, result: ko())
        #expect(ledger.check(c, page: "A") == .run)
        ran(&ledger, c, step: 2, result: ko())
        if case .refuse(let why) = ledger.check(c, page: "A") { #expect(why.contains("2 fois")) } else { Issue.record("à abandonner") }
    }

    @Test("rouvrir la page où l'on est déjà est refusé")
    func sameURL() {
        let ledger = ActionLedger()
        if case .refuse = ledger.check(call("open_url", "{\"url\":\"https://www.example.com/a/\"}"), page: "A", currentURL: "https://example.com/a") {} else { Issue.record("déjà ouverte") }
        #expect(ledger.check(call("open_url", "{\"url\":\"https://example.com/b\"}"), page: "A", currentURL: "https://example.com/a") == .run)
    }

    @Test("le défilement répété sans effet est arrêté")
    func scrolling() {
        var ledger = ActionLedger()
        let c = call("scroll", "{\"direction\":\"down\"}")
        for step in 1...3 { #expect(ledger.check(c, page: "A") == .run); ran(&ledger, c, step: step, page: "A", result: ok()) }
        if case .refuse = ledger.check(c, page: "A") {} else { Issue.record("fin de page") }
        #expect(ledger.check(c, page: "B") == .run)
    }

    @Test("une tâche qui tourne en rond est détectée, puis le progrès remet à zéro")
    func stalled() {
        var ledger = ActionLedger()
        for _ in 0..<2 { ledger.noteProgress(false) }
        #expect(!ledger.isStalled)
        ledger.noteProgress(false)
        #expect(ledger.isStalled)
        ledger.noteProgress(true)
        #expect(!ledger.isStalled)
    }

    @Test("le résumé pour le modèle garde plus de texte pour les recherches")
    func summary() {
        var ledger = ActionLedger()
        let long = String(repeating: "x", count: 900)
        ran(&ledger, call("search_web", "{\"query\":\"a\"}"), step: 1, result: ok(long))
        ran(&ledger, call("read_page"), step: 2, result: ok(long))
        let text = ledger.summary()
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2 && lines[0].count > lines[1].count && lines[0].contains("OK"))
    }
}
