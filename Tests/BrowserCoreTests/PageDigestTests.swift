import Testing
import Foundation
@testable import BrowserCore

@Suite struct PageDigestTests {
    private let recipeLD = """
    {"@context":"https://schema.org","@graph":[{"@type":"WebSite","name":"Site"},
    {"@type":"Recipe","name":"Easy pancakes","description":"Foolproof <b>crêpes</b> &amp; more","prepTime":"PT10M","cookTime":"PT1H30M","totalTime":"PT1H40M",
     "recipeYield":["12","12 pancakes"],
     "recipeIngredient":["100g plain flour","2 large eggs"],
     "recipeInstructions":[{"@type":"HowToStep","text":"Whisk the flour and eggs."},
        {"@type":"HowToSection","name":"Cook","itemListElement":[{"@type":"HowToStep","text":"Fry for 1 min."}]}]}]}
    """

    @Test func aRecipeIsReadExactlyFromStructuredData() throws {
        let digest = try #require(DigestParser.fromStructuredData([recipeLD], pageTitle: "fallback"))
        #expect(digest.kind == .recipe && digest.source == .structured)
        #expect(digest.title == "Easy pancakes")
        #expect(digest.summary == "Foolproof crêpes & more")                       // tags and entities removed
        #expect(digest.ingredients == ["100g plain flour", "2 large eggs"])
        #expect(digest.steps == ["Whisk the flour and eggs.", "Fry for 1 min."])  // a section's steps are flattened in order
        #expect(digest.times == ["Préparation : 10 min", "Cuisson : 1 h 30 min", "Total : 1 h 40 min"])
        #expect(digest.servings == 12)                                                 // the yield feeds the servings slider, not a text line
    }

    @Test func aHowToAndStringInstructionsAreUnderstood() throws {
        let howTo = #"{"@type":"HowTo","name":"Change a tyre","totalTime":"PT30M","tool":[{"@type":"HowToTool","name":"Jack"}],"step":[{"@type":"HowToStep","text":"Loosen the nuts."},{"@type":"HowToStep","text":"Lift the car."}]}"#
        let digest = try #require(DigestParser.fromStructuredData([howTo], pageTitle: "x"))
        #expect(digest.kind == .tutorial && digest.steps.count == 2 && digest.ingredients == ["Jack"] && digest.times == ["Durée : 30 min"])
        let flat = #"{"@type":"Recipe","name":"R","recipeInstructions":"Mix.<br>Bake.\nServe."}"#
        #expect(try #require(DigestParser.fromStructuredData([flat], pageTitle: "x")).steps == ["Mix.", "Bake.", "Serve."])
    }

    @Test func pagesWithoutARecipeGiveNothing() {
        #expect(DigestParser.fromStructuredData([#"{"@type":"Article","name":"News"}"#, "not json", "[]"], pageTitle: "x") == nil)
        #expect(DigestParser.fromStructuredData([#"{"@type":"Recipe","name":"Empty"}"#], pageTitle: "x") == nil)
    }

    @Test func durationsAreFormatted() {
        #expect(DigestParser.formatDuration("PT45M") == "45 min")
        #expect(DigestParser.formatDuration("PT2H") == "2 h")
        #expect(DigestParser.formatDuration("P1DT2H") == "1 j 2 h")
        #expect(DigestParser.formatDuration("PT0M") == nil)
        #expect(DigestParser.formatDuration("10 minutes") == nil)
    }

    @Test func theModelsJSONIsReadEvenInACodeFenceWithLooseKeys() throws {
        let answer = """
        Voici :
        ```json
        {"INGRÉDIENTS": ["100g farine", "2 œufs"], "ÉTAPES": ["Mélanger.", "Cuire."], "TEMPS": "Préparation : 10 min"}
        ```
        """
        let digest = try #require(DigestParser.fromModel(answer, pageTitle: "Crêpes"))
        #expect(digest.kind == .recipe && digest.source == .model && digest.title == "Crêpes")
        #expect(digest.ingredients.count == 2 && digest.steps == ["Mélanger.", "Cuire."] && digest.times == ["Préparation : 10 min"])
        let review = try #require(DigestParser.fromModel(#"{"type":"comparatif","verdict":"Le A est meilleur.","pour":["Rapide"],"contre":["Cher"]}"#, pageTitle: "t"))
        #expect(review.kind == .review && review.pros == ["Rapide"] && review.cons == ["Cher"])
    }

    @Test func anAnswerWithNothingUsableIsRejected() {
        #expect(DigestParser.fromModel("Je ne sais pas.", pageTitle: "t") == nil)
        #expect(DigestParser.fromModel(#"{"ingredients": [], "steps": []}"#, pageTitle: "t") == nil)
    }

    @Test func invented_or_translatedItemsAreDroppedAgainstThePageText() {
        let page = "Put 100g plain flour, 2 large eggs and 300ml milk into a bowl, then whisk to a smooth batter."
        let digest = PageDigest(kind: .recipe, title: "t", ingredients: ["100g plain flour", "2 large eggs", "un peu d'eau salée", "du sucre glace"],
                                steps: ["Whisk to a smooth batter.", "Add truffle shavings and gold leaf."], source: .model)
        let (checked, dropped) = DigestValidator.checked(digest, against: page)
        #expect(checked.ingredients == ["100g plain flour", "2 large eggs"])
        #expect(checked.steps == ["Whisk to a smooth batter."])
        #expect(dropped == 3)
    }

    @Test func theModelGetsABoundedTextKeepingStartAndEnd() {
        let text = String(repeating: "a", count: 3000) + String(repeating: "b", count: 3000) + String(repeating: "c", count: 3000)
        let cut = DigestValidator.budget(text, characters: 1000)
        #expect(cut.count < 1100 && cut.hasPrefix("aaa") && cut.hasSuffix("ccc") && cut.contains("[…]"))
        #expect(DigestValidator.budget("short") == "short")
    }

    @Test func theRenderedPageEscapesEverythingFromThePage() {
        let digest = PageDigest(kind: .recipe, title: "<script>alert(1)</script>", ingredients: ["a & b"], steps: ["<img src=x onerror=1>"], source: .structured)
        let style = DigestRenderer.Style(fontFace: "", variables: "--page:#fff;", darkVariables: "--page:#000;", radiusSmall: 6, radius: 10, radiusLarge: 14)
        let html = DigestRenderer.html(digest, style: style, cooking: false, notice: "<b>x</b>")
        #expect(!html.contains("<script>") && !html.contains("<img") && !html.contains("<b>x"))
        #expect(html.contains("&lt;script&gt;") && html.contains("a &amp; b"))
        #expect(DigestRenderer.html(digest, style: style, cooking: true, notice: nil).contains("font:400 28px"))      // kitchen mode: big text
    }

    @Test func theRenderedPageSpeaksTheDesignSystemsLanguage() {
        let digest = PageDigest(kind: .recipe, title: "Cookies", times: ["Cuisson : 10 min"], ingredients: ["85 g de beurre"], steps: ["Mélanger."], source: .structured)
        let style = DigestRenderer.Style(fontFace: "@font-face{font-family:\"Instrument Sans\"}", variables: "--page:#FBFAF7;--h:#2F7354;", darkVariables: "--page:#1E1D1B;",
                                         radiusSmall: 6, radius: 10, radiusLarge: 14)
        let html = DigestRenderer.html(digest, style: style, cooking: false, notice: nil)
        #expect(html.contains("--page:#FBFAF7;--h:#2F7354;") && html.contains("prefers-color-scheme: dark") && html.contains("--page:#1E1D1B;"))
        #expect(html.contains("Instrument Serif") && html.contains("italic 400 54px") && html.contains("--r-lg:14px"))
        #expect(html.contains("class=\"chip\">Cuisson : 10 min") && html.contains("<span class=\"kind\">Recette</span>"))
        #expect(html.contains("type=\"checkbox\"") && !html.contains("<script"))          // ticking works without JavaScript
    }

    @Test func theYieldBecomesAServingsSlider() throws {
        let digest = try #require(DigestParser.fromStructuredData([recipeLD], pageTitle: "x"))
        #expect(digest.servings == 12 && digest.servingsLabel == "personnes")          // the first yield ("12") has no noun: people
        #expect(!digest.times.contains { $0.hasPrefix("Pour") })                                                             // the slider replaces the line
        #expect(DigestParser.parseYield("4 personnes")?.count == 4 && DigestParser.parseYield("4 personnes")?.label == "personnes")
        #expect(DigestParser.parseYield("12 crêpes")?.label == "crêpes")
        #expect(DigestParser.parseYield("6")?.label == "personnes")
        #expect(DigestParser.parseYield("pour 4 à 6 personnes")?.count == 4)
        #expect(DigestParser.parseYield("beaucoup") == nil && DigestParser.parseYield("0 personnes") == nil)
    }

    @Test func theRenderedRecipeCarriesTheSliderAndAllTheScaledQuantities() {
        let digest = PageDigest(kind: .recipe, title: "t", ingredients: ["85 g de beurre", "1 oeuf", "du sel"], steps: ["Cuire."], source: .structured, servings: 4, servingsLabel: "personnes")
        let style = DigestRenderer.Style(fontFace: "", variables: "", darkVariables: "", radiusSmall: 6, radius: 10, radiusLarge: 14)
        let html = DigestRenderer.html(digest, style: style, cooking: false, notice: nil)
        #expect(html.contains("type=\"range\"") && html.contains("4 personnes") && html.contains("data-i=\"0\""))
        #expect(html.contains("170 g de beurre") && html.contains("2 oeuf") && html.contains("du sel"))        // the table for 8 servings
        #expect(html.contains("Content-Security-Policy"))
    }

    @Test func thePagesTextCannotBreakOutOfTheScript() {
        let digest = PageDigest(kind: .recipe, title: "t", ingredients: ["2 </script><script>alert(1)</script>"], source: .structured, servings: 2, servingsLabel: "</script>")
        let style = DigestRenderer.Style(fontFace: "", variables: "", darkVariables: "", radiusSmall: 6, radius: 10, radiusLarge: 14)
        let html = DigestRenderer.html(digest, style: style, cooking: false, notice: nil)
        #expect(html.components(separatedBy: "</script>").count == 2)           // exactly one closing tag: ours
        #expect(!html.contains("<script>alert"))
    }
}
