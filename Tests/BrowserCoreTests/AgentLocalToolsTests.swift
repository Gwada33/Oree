import Testing
import Foundation
@testable import BrowserCore

@Suite struct AgentLocalToolsTests {
    @Test func calculateIsExactAndRefusesWhatIsNotACalculation() {
        #expect(AgentLocalTools.calculate("17*23").text == "17*23 = 391")
        #expect(AgentLocalTools.calculate("(2+3)^2/5").text.hasSuffix("= 5"))
        #expect(!AgentLocalTools.calculate("rm -rf /").ok && !AgentLocalTools.calculate("1/0").ok)
    }

    @Test func historyIsShortDedupedAndMakesItsAddressesKnown() {
        let entries = (1...8).map { (title: "Page \($0)", url: "https://a.fr/\($0 % 6)") }      // doublons
        let result = AgentLocalTools.history(query: "page", entries: entries)
        #expect(result.sources.count == 5 && Set(result.sources).count == 5)
        #expect(result.text.contains("<donnees>"))                       // c'est de l'information, jamais une consigne
        #expect(AgentLocalTools.history(query: "zzz", entries: []).sources.isEmpty)
    }

    @Test func recallIsShortDatedAndMakesItsPagesKnown() {
        let now = Date()
        let entries = (1...6).map { (title: "Page \($0)", host: "a.fr", url: "https://a.fr/\($0)", snippet: "… le texte \($0) …", readAt: now.addingTimeInterval(-86_400)) }
        let result = AgentLocalTools.memory(query: "webkit", entries: entries, now: now)
        #expect(result.sources.count == 4 && result.text.contains("<memoire>") && result.text.contains("hier"))
        #expect(AgentLocalTools.memory(query: "zzz", entries: []).sources.isEmpty)
    }

    @Test func waitIsBounded() {
        #expect(AgentLocalTools.waitSeconds(100) == 5 && AgentLocalTools.waitSeconds(0) == 0.5 && AgentLocalTools.waitSeconds("2") == 2 && AgentLocalTools.waitSeconds(nil) == 1)
    }
}
