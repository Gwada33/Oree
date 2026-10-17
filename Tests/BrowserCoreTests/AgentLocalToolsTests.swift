import Testing
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

    @Test func waitIsBounded() {
        #expect(AgentLocalTools.waitSeconds(100) == 5 && AgentLocalTools.waitSeconds(0) == 0.5 && AgentLocalTools.waitSeconds("2") == 2 && AgentLocalTools.waitSeconds(nil) == 1)
    }
}
