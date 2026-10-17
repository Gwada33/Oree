import Testing
import Foundation
@testable import BrowserCore

@Suite struct SmallModelToleranceTests {
    @Test func refsSurviveStrayCharacters() throws {
        let action = try AIAction.parse(name: "fill_form", argumentsJSON: #"{"fields":{"@e3":"Marie","(@e4":"Dupont","@e5:":"a@b.fr"}}"#)
        guard case .fillForm(let fields) = action else { Issue.record("pas un fill_form"); return }
        #expect(fields.map(\.ref) == [3, 4, 5])
        #expect(AIAction.ref("e12") == 12 && AIAction.ref(7) == 7 && AIAction.ref("rien") == nil)
    }

    @Test func inventedAddressIsRefusedWhenTheRequestNamesOne() {
        let task = "Ouvre https://www.wikipedia.org"
        #expect(OpenURLGuard.problem(task: task, urlString: "https://www.exemple.fr", knownSources: []) != nil)
        #expect(OpenURLGuard.problem(task: task, urlString: "https://wikipedia.org/wiki/Lyon", knownSources: []) == nil)
        #expect(OpenURLGuard.problem(task: task, urlString: "https://fr.example.org/x", knownSources: ["https://fr.example.org/y"]) == nil)
    }

    @Test func noAddressInTheRequestMeansNoConstraint() {
        #expect(OpenURLGuard.problem(task: "cherche la météo à Lyon", urlString: "https://meteo.fr", knownSources: []) == nil)
    }
}
