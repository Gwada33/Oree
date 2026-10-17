import Testing
@testable import BrowserCore

@Suite struct PersonalValueGuardTests {
    @Test func tokensAndValuesFromTheRequestAreAllowed() {
        #expect(PersonalValueGuard.problem(task: "Remplis mon prénom", values: ["{{profil.prenom}}"]) == nil)
        #expect(PersonalValueGuard.problem(task: "Mets Marie Dupont, marie@test.fr", values: ["Marie", "marie@test.fr"]) == nil)
    }
    @Test func madeUpPersonalDataIsRefused() {
        #expect(PersonalValueGuard.problem(task: "Remplis mon prénom", values: ["Luc"]) != nil)       // « mon » : ce sont ses informations
        #expect(PersonalValueGuard.problem(task: "Ajoute au panier", values: ["evil.test"]) != nil)    // une adresse que la demande n'a pas citée
        #expect(PersonalValueGuard.problem(task: "Inscris-moi", values: ["+33 6 12 34 56 78"]) != nil)
    }
    @Test func ordinaryTextIsLeftAlone() {
        #expect(PersonalValueGuard.problem(task: "Cherche des casques sur le site", values: ["casque sans fil"]) == nil)
    }
    @Test func readsValuesOfEachTool() {
        #expect(PersonalValueGuard.values(of: AgentCall(name: "type", argumentsJSON: #"{"ref":"@e1","text":"a"}"#)) == ["a"])
        #expect(PersonalValueGuard.values(of: AgentCall(name: "fill_form", argumentsJSON: #"{"fields":{"@e1":"a"}}"#)) == ["a"])
        #expect(PersonalValueGuard.values(of: AgentCall(name: "click", argumentsJSON: #"{"ref":"@e1"}"#)).isEmpty)
    }
}
