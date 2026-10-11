import Testing
@testable import BrowserCore

@Suite struct PageMapTests {
    private func element(_ ref: Int, visible: Bool = true, form: Bool = false, nav: Bool = false, label: String = "x") -> PageMap.Element {
        .init(ref: ref, role: "link", label: label, visible: visible, inForm: form, inNav: nav)
    }

    @Test func formatMatchesTheContract() {
        let map = PageMap(url: "https://a.fr/", title: "Accueil", elements: [
            .init(ref: 1, role: "link", label: "Contact", visible: true, attributes: ["href": "/contact"]),
            .init(ref: 2, role: "input", type: "email", label: "Courriel", visible: true, attributes: ["required": ""]),
        ], blocks: [.init(tag: "h1", text: "Bonjour")])
        #expect(map.render() == """
        PAGE https://a.fr/ "Accueil"
        VISIBLE
        @e1 link "Contact" href="/contact"
        @e2 input[email] "Courriel" required
        TEXTE
        [h1] Bonjour
        """)
    }

    @Test func budgetKeepsVisibleThenFormsThenNav() {
        var list: [PageMap.Element] = (1...50).map { element($0, visible: false) }          // 50 éléments sans priorité
        list += [element(100, visible: false, nav: true), element(101, visible: false, form: true)] + (200...230).map { element($0) }   // 31 visibles
        let text = PageMap(url: "u", title: "t", elements: list, blocks: []).render()
        #expect(text.contains("@e200 ") && text.contains("@e230 "))      // tous les visibles
        #expect(text.contains("@e101 "))                                  // le formulaire passe avant…
        #expect(text.contains("@e100 "))                                  // …la navigation, avant le reste
        #expect(!text.contains("@e50 "))                                  // le reste est coupé
        #expect(text.contains("AUTRES +\(list.count - PageMap.maxElements)"))
        #expect(text.components(separatedBy: "\n@e").count - 1 == PageMap.maxElements)
    }

    @Test func secretsAreDetected() {
        #expect(PageMap.isSecret(type: "password", hints: []))
        #expect(PageMap.isSecret(type: "text", hints: ["cc-number"]))
        #expect(PageMap.isSecret(type: nil, hints: ["Numéro de carte"]))
        #expect(!PageMap.isSecret(type: "email", hints: ["email"]))
    }

    @Test func quotesAndLongLabelsAreTamed() {
        let long = String(repeating: "a", count: 200)
        let text = PageMap(url: "u", title: "Un \"titre\"", elements: [element(1, label: long + "\"x\"")], blocks: []).render()
        #expect(text.contains("PAGE u \"Un 'titre'\""))
        #expect(!text.contains(long))
    }

    @Test func textIsCappedAndTokensEstimated() {
        let blocks = (0..<100).map { _ in PageMap.Block(tag: "p", text: String(repeating: "mot ", count: 90)) }
        let text = PageMap(url: "u", title: "t", elements: [], blocks: blocks).render()
        #expect(text.hasSuffix("[…]"))
        #expect(PageMap.estimatedTokens(text) < 2000)
    }
}
