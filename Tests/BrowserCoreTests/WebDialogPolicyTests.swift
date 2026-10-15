import Testing
import Foundation
@testable import BrowserCore

@Suite struct WebDialogPolicyTests {
    @Test func theDialogNamesTheSite() {
        let url = URL(string: "https://www.exemple.fr/page")
        #expect(WebDialogPolicy.alert(message: "Salut", frame: url).title == "« exemple.fr » indique")
        #expect(WebDialogPolicy.confirm(message: "Sûr ?", frame: url).title == "« exemple.fr » demande confirmation")
        #expect(WebDialogPolicy.prompt(message: "Ton nom ?", frame: url).title == "« exemple.fr » demande une réponse")
        #expect(WebDialogPolicy.alert(message: "x", frame: nil).title == "« Une page » indique")
    }

    @Test func onlyConfirmAndPromptCanBeCancelled() {
        #expect(WebDialogPolicy.alert(message: "x", frame: nil).cancelTitle == nil)
        #expect(WebDialogPolicy.confirm(message: "x", frame: nil).cancelTitle == "Annuler")
        #expect(WebDialogPolicy.prompt(message: "x", frame: nil).cancelTitle == "Annuler")
    }

    @Test func aHugeMessageIsCut() {
        let long = String(repeating: "a", count: 5000)
        let shown = WebDialogPolicy.alert(message: long, frame: nil).message
        #expect(shown.count == WebDialogPolicy.maxMessageLength + 1 && shown.hasSuffix("…"))
        #expect(WebDialogPolicy.alert(message: "court", frame: nil).message == "court")
    }
}
