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

@Suite("Passages de la page choisis selon la question")
struct PageMapFocusTests {
    private func map(_ blocks: [(String, String)]) -> PageMap {
        PageMap(url: "https://x.example/", title: "T", elements: [], blocks: blocks.map { PageMap.Block(tag: $0.0, text: $0.1) })
    }
    private let filler = String(repeating: "mot ", count: 60)          // 240 caractères

    @Test("tout tient : tout est donné, question ou non")
    func fits() {
        let page = map([("h1", "Porto"), ("p", "Ville du Portugal."), ("p", "Fondée il y a longtemps.")])
        let out = page.render(maxElements: 0, maxText: 2000, focus: "population")
        #expect(out.contains("Ville du Portugal.") && out.contains("Fondée il y a longtemps.") && !out.contains("[…]"))
    }

    @Test("trop long : les passages qui parlent de la question passent, même loin dans la page")
    func picksRelevant() {
        var blocks: [(String, String)] = [("h1", "Porto"), ("p", "Porto est une ville du Portugal.")]
        for i in 0..<20 { blocks.append(("p", "Paragraphe \(i) sur l'histoire. " + filler)) }
        blocks.append(("h2", "Démographie"))
        blocks.append(("p", "La population de la ville atteint 273 476 habitants en 2025."))
        let page = map(blocks)
        let focused = page.render(maxElements: 0, maxText: 900, focus: "Quelle est la population de Porto ?")
        #expect(focused.contains("273 476 habitants"))
        #expect(focused.contains("[h1] Porto") && focused.contains("[h2] Démographie"))
        #expect(focused.contains("[…]"))
        // Sans question, on garde le début : la population, tout au fond, n'y est pas.
        #expect(!page.render(maxElements: 0, maxText: 900).contains("273 476"))
    }

    @Test("aucun passage en rapport : le début de la page, comme avant")
    func noMatch() {
        var blocks: [(String, String)] = []
        for i in 0..<12 { blocks.append(("p", "Texte \(i). " + filler)) }
        let out = map(blocks).render(maxElements: 0, maxText: 700, focus: "zzzz introuvable")
        #expect(out.contains("Texte 0.") && !out.contains("Texte 11.") && out.contains("[…]"))
    }

    @Test("le budget est respecté")
    func budget() {
        var blocks: [(String, String)] = []
        for i in 0..<30 { blocks.append(("p", "Sujet porto \(i). " + filler)) }
        let text = map(blocks).render(maxElements: 0, maxText: 1000, focus: "porto").components(separatedBy: "TEXTE\n").last ?? ""
        let body = text.split(separator: "\n").filter { !$0.hasPrefix("[…]") }.joined().count
        #expect(body <= 1000 + 5 * 12)       // la limite en caractères de texte, plus les marques « [p] »
    }
}
