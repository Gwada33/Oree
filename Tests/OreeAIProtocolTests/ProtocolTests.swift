import Testing
import Foundation
@testable import OreeAIProtocol

@Suite struct ProtocolTests {
    @Test func everyEventSurvivesJSON() {
        let events: [AIEvent] = [
            .textDelta(taskID: "t", text: "Bonjour"),
            .toolCall(taskID: "t", callID: "c1", name: "click", argumentsJSON: #"{"ref":"@e3"}"#),
            .needsConfirmation(taskID: "t", callID: "c2", summary: "Envoyer le formulaire"),
            .done(taskID: "t", answer: "Voilà", sources: ["https://example.com"]),
            .error(taskID: nil, message: "modèle absent"),
            .stateChanged(AIStatus(state: .tepid, model: .ready)),
            .modelProgress(received: 1, total: 2),
        ]
        for event in events { #expect(AIEvent.decode(event.encoded()) == event) }
    }

    @Test func garbageIsNotAnEvent() { #expect(AIEvent.decode(Data("pas du json".utf8)) == nil) }

    @Test func runRequestRoundTrips() throws {
        let request = AIRunRequest(userText: "Résume cette page", pageMap: nil)
        #expect(try JSONDecoder().decode(AIRunRequest.self, from: JSONEncoder().encode(request)) == request)
    }
}
