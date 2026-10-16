import Foundation
import JavaScriptCore
import Testing
@testable import BrowserCore

@Suite("Refus automatique des bannières de cookies")
struct CookieBannerScriptTests {
    private func matches(_ text: String) -> Bool {
        let context = JSContext()!
        context.evaluateScript("var re = new RegExp(\(JSONEncoderString.quote(CookieBannerScript.rejectPattern)), 'i');")
        return context.evaluateScript("re.test(\(JSONEncoderString.quote(text)))")?.toBool() ?? false
    }

    @Test("les boutons de refus, en français et en anglais, sont reconnus (casse et accents compris)")
    func rejects() {
        for text in ["Tout refuser", "Refuser", "Refuser tout", "TOUT REFUSER", "Continuer sans accepter", "Non merci", "Rejeter tout", "Reject all", "Decline", "Deny all", "Only necessary cookies",
                     "Uniquement les cookies nécessaires", "Cookies essentiels uniquement", "Refuse all", "Continue without accepting", "Refuser et fermer"] {
            #expect(matches(text), "« \(text) » est un refus")
        }
    }

    @Test("jamais un bouton qui accepte, personnalise, ou dit autre chose (le texte entier doit être un refus)")
    func neverAcceptsOrGuesses() {
        for text in ["Tout accepter", "Accepter", "Accept all", "J'accepte", "Personnaliser", "Paramétrer les cookies", "Manage preferences", "Cookie settings", "OK", "Fermer", "En savoir plus",
                     "Refuser l'invitation de Paul", "Refuser la livraison à domicile", "Reject the proposal and continue editing the document", "Je refuse de partager mes données à mes partenaires publicitaires", ""] {
            #expect(!matches(text), "« \(text) » ne doit PAS être cliqué")
        }
    }

    @Test("le script est du JavaScript valide, avec les sélecteurs connus et sans bouton « accepter »")
    func scriptIsValid() {
        let source = CookieBannerScript.source
        let context = JSContext()!
        var failure: String?
        context.exceptionHandler = { _, e in failure = e?.toString() }
        context.evaluateScript("var window = { webkit: { messageHandlers: {} } }; var document = { documentElement: {}, querySelector: function(){ return null }, querySelectorAll: function(){ return [] } }; var MutationObserver = function(){ this.observe = function(){}; this.disconnect = function(){} }; function setTimeout(){}; function getComputedStyle(){ return {} };")
        context.evaluateScript(source)
        #expect(failure == nil, "\(failure ?? "")")
        #expect(source.contains("#onetrust-reject-all-handler") && source.contains("didomi-notice-disagree-button"))
        #expect(CookieBannerScript.knownSelectors.allSatisfy { selector in
            let lower = selector.lowercased().replacingOccurrences(of: "disagree", with: "").replacingOccurrences(of: "without-agreeing", with: "")       // « disagree » et « continuer sans accepter » sont des refus
            return !lower.contains("accept") && !lower.contains("allow") && !lower.contains("agree") && !lower.contains("optin-accept")
        })
        #expect(context.evaluateScript("window.__hbCookie")?.toBool() == true)
    }
}
