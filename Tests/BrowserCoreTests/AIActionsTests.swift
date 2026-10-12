import Testing
import Foundation
@testable import BrowserCore

@Suite struct AIActionsTests {
    let page = URL(string: "https://shop.example/cart")

    @Test func toolCallsAreParsed() throws {
        #expect(try AIAction.parse(name: "click", argumentsJSON: #"{"ref":"@e12"}"#) == .click(ref: 12))
        #expect(try AIAction.parse(name: "click", argumentsJSON: #"{"ref":3}"#) == .click(ref: 3))
        #expect(try AIAction.parse(name: "type", argumentsJSON: #"{"ref":"e4","text":"Lisbonne"}"#) == .type(ref: 4, text: "Lisbonne", submit: false))
        #expect(try AIAction.parse(name: "fill_form", argumentsJSON: #"{"fields":{"@e2":"a","@e1":"b"}}"#) == .fillForm(fields: [(1, "b"), (2, "a")]))
        #expect(throws: AIAction.ParseError.unknownTool("rm")) { try AIAction.parse(name: "rm", argumentsJSON: "{}") }
        #expect(throws: AIAction.ParseError.badArguments("ref")) { try AIAction.parse(name: "click", argumentsJSON: "{}") }
        #expect(throws: AIAction.ParseError.badArguments("direction")) { try AIAction.parse(name: "scroll", argumentsJSON: #"{"direction":"sideways"}"#) }
    }

    @Test func sensitiveClicksNeedConfirmation() {
        func click(_ t: ActionTarget) -> ActionDecision { ActionPolicy.decide(.click(ref: t.ref), target: t, pageURL: page) }
        #expect(click(.init(ref: 1, tag: "a", label: "Accueil")) == .allow)
        if case .confirm = click(.init(ref: 2, tag: "button", label: "Continuer", isSubmit: true, inForm: true)) {} else { Issue.record("submit sans confirmation") }
        if case .confirm = click(.init(ref: 3, tag: "button", label: "Payer 49 €")) {} else { Issue.record("paiement sans confirmation") }
        if case .confirm = click(.init(ref: 4, tag: "a", label: "Voir", href: "/files/rapport.zip")) {} else { Issue.record("téléchargement sans confirmation") }
        if case .confirm = click(.init(ref: 5, tag: "a", label: "Voir", href: "/x", download: true)) {} else { Issue.record("download sans confirmation") }
    }

    @Test func secretsAndInternalPagesAreRefused() {
        let password = ActionTarget(ref: 1, tag: "input", type: "password", label: "Mot de passe")
        if case .refuse = ActionPolicy.decide(.type(ref: 1, text: "x", submit: false), target: password, pageURL: page) {} else { Issue.record("mot de passe rempli") }
        let field = ActionTarget(ref: 2, tag: "input", type: "text", label: "Nom")
        #expect(ActionPolicy.decide(.type(ref: 2, text: "x", submit: false), target: field, pageURL: page) == .allow)
        if case .confirm = ActionPolicy.decide(.type(ref: 2, text: "x", submit: true), target: field, pageURL: page) {} else { Issue.record("submit sans confirmation") }
        if case .refuse = ActionPolicy.decide(.click(ref: 2), target: field, pageURL: URL(string: "oree://settings")) {} else { Issue.record("page interne") }
        if case .refuse = ActionPolicy.decide(.scroll(direction: "down"), target: field, pageURL: nil) {} else { Issue.record("sans page") }
    }

    @Test func secretFieldsAreMaskedOnTheConfirmationCard() {
        #expect(ActionTarget.Field(label: "Carte", value: "", secret: true, last4: "4242").shown == "•••• 4242")
        #expect(ActionTarget.Field(label: "Mot de passe", value: "", secret: true).shown == "••••••••")
        #expect(ActionTarget.Field(label: "Nom", value: "Nolhan").shown == "Nolhan")
    }

    @Test func writingProfileDataNeedsConfirmation() {
        let field = ActionTarget(ref: 2, tag: "input", type: "text", label: "Nom")
        if case .confirm = ActionPolicy.decide(.type(ref: 2, text: "{{profil.nom}}", submit: false), target: field, pageURL: page) {} else { Issue.record("jeton de profil sans accord") }
        if case .confirm = ActionPolicy.decide(.select(ref: 2, option: "{{profil.pays}}"), target: field, pageURL: page) {} else { Issue.record("jeton de profil sans accord (liste)") }
        #expect(ActionPolicy.decide(.type(ref: 2, text: "Lisbonne", submit: false), target: field, pageURL: page) == .allow)
    }

    @Test func profileTokensAreResolvedIndividually() throws {
        let profile = ["nom": "Galinat", "prenom": "Nolhan"]
        #expect(try ProfileTokens.resolve("{{profil.prenom}} {{ profil.nom }}", profile: profile) == "Nolhan Galinat")
        #expect(try ProfileTokens.resolve("sans jeton", profile: profile) == "sans jeton")
        #expect(throws: ProfileTokens.TokenError.unknown("ville")) { try ProfileTokens.resolve("{{profil.ville}}", profile: profile) }
        // Une valeur qui ressemble à un jeton n'est pas réinterprétée.
        #expect(try ProfileTokens.resolve("{{profil.nom}}", profile: ["nom": "{{profil.prenom}}", "prenom": "X"]) == "{{profil.prenom}}")
        #expect(ProfileTokens.keys(in: "{{profil.a}} et {{profil.b}}") == ["a", "b"])
    }
}
