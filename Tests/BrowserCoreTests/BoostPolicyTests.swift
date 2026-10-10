import Testing
import Foundation
@testable import BrowserCore

@Suite struct BoostPolicyTests {
    @Test func plainSelectorsPassAndEscapesFail() {
        #expect(BoostPolicy.sanitize(selector: "ytd-reel-shelf-renderer") == "ytd-reel-shelf-renderer")
        #expect(BoostPolicy.sanitize(selector: "#related, .promo > a") == "#related, .promo > a")
        #expect(BoostPolicy.sanitize(selector: "a[href*='shorts']") == "a[href*='shorts']")
        for evil in ["x } body { display:none", "x; y", "a{b}", "@import url(x)", "a\\b", "a /* c */", "x:after{content:url(http://e)}", "<script>"] {
            #expect(BoostPolicy.sanitize(selector: evil) == nil, "\(evil)")
        }
        #expect(BoostPolicy.sanitize(selector: String(repeating: "a", count: 500)) == nil)
        #expect(BoostPolicy.sanitize(selector: "  ") == nil)
    }

    @Test func selectorsThatWouldRestyleTheWholePageAreRefused() {
        for broad in ["*", "html", "body", ":root", "div", "span", "a", "main", "#ok, body", "html body"] {
            #expect(BoostPolicy.sanitize(selector: broad) == nil, "\(broad)")
        }
        #expect(BoostPolicy.sanitize(selector: "body.home .banner") != nil)
    }

    @Test func onlyAllowedLooksWithSafeValuesSurvive() {
        let clean = BoostPolicy.sanitize(declarations: [
            "display": "none", "FONT-SIZE": "20px !important", "color": "#222",
            "position": "fixed",                                   // not allowed: could cover the page
            "background-image": "url(http://evil/x.png)",           // not allowed, and a request
            "background-color": "red; } body { display: none",       // a way out of the rule
            "font-family": "url(x)", "width": "",
        ])
        #expect(clean == ["display": "none", "font-size": "20px", "color": "#222"])
    }

    @Test func modelAnswersAreParsedWhateverTheirShape() {
        let answer = """
        Voici :
        ```json
        {"regles": [
          {"selecteur": "ytd-reel-shelf-renderer", "declarations": {"display": "none"}},
          {"selector": "#related", "declarations": "display: none; color: red; position: fixed"},
          {"selecteur": "body", "declarations": {"display": "none"}},
          {"selecteur": ".x { y", "declarations": {"display": "none"}},
          {"selecteur": ".ok", "declarations": {"position": "fixed"}}
        ], "calme": true}
        ```
        """
        let (rules, calm) = BoostPolicy.rules(fromModel: answer)
        #expect(calm)
        #expect(rules.map(\.selector) == ["ytd-reel-shelf-renderer", "#related"])
        #expect(rules[1].declarations == ["display": "none", "color": "red"])
        #expect(BoostPolicy.rules(fromModel: "je ne sais pas").rules.isEmpty)
    }

    @Test func theStylesheetForcesTheUsersWish() {
        let css = BoostPolicy.css(for: [BoostRule(selector: ".promo", declarations: ["display": "none", "color": "red"])])
        #expect(css == ".promo { color: red !important; display: none !important }")
    }

    @Test func aRuleMustMatchSomethingButNotMostOfThePage() {
        #expect(!BoostPolicy.isUseful(matches: 0, pageElements: 1000))
        #expect(BoostPolicy.isUseful(matches: 12, pageElements: 1000))
        #expect(!BoostPolicy.isUseful(matches: 800, pageElements: 1000))
        #expect(BoostPolicy.isUseful(matches: 3, pageElements: 4))              // tiny pages: a few matches are fine
    }

    @Test func thePromptListsRealElementsWithinTheBudget() {
        let candidates = (0..<500).map { BoostPrompt.Candidate(selector: ".item-\($0)", count: 2, text: "texte \"cité\" \($0)") }
        let prompt = BoostPrompt.prompt(request: "cache les Shorts", host: "youtube.com", candidates: candidates, characters: 400)
        #expect(prompt.hasPrefix("Site : youtube.com\nDemande : cache les Shorts"))
        #expect(prompt.contains(".item-0 ×2 \"texte 'cité' 0\""))              // quotes inside a text cannot break the line
        #expect(prompt.count < 400 + 120 && !prompt.contains(".item-499"))
    }

    @Test func aRuleThatHidesMostOfTheTextIsDropped() {
        let hide = BoostRule(selector: ".content", declarations: ["display": "none"])
        let bigger = BoostRule(selector: ".content", declarations: ["font-size": "20px"])
        #expect(BoostPolicy.hides(hide) && !BoostPolicy.hides(bigger))
        #expect(BoostPolicy.hides(BoostRule(selector: ".a", declarations: ["opacity": "0"])))
        #expect(!BoostPolicy.isAcceptable(hide, matches: 1, pageElements: 400, matchedText: 5000, pageText: 9000))      // the article
        #expect(BoostPolicy.isAcceptable(hide, matches: 3, pageElements: 400, matchedText: 300, pageText: 9000))        // the ads
        #expect(BoostPolicy.isAcceptable(bigger, matches: 1, pageElements: 400, matchedText: 5000, pageText: 9000))     // making text bigger is fine
        #expect(!BoostPolicy.isAcceptable(hide, matches: 0, pageElements: 400, matchedText: 0, pageText: 9000))
    }
}
