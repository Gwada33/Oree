import Testing
import Foundation
@testable import BrowserCore

@Suite struct IngredientScalerTests {
    private func scaled(_ line: String, _ factor: Double) -> String { IngredientScaler.scaled(line, factor: factor) }

    @Test func leadingQuantitiesAreScaled() {
        #expect(scaled("85 g de beurre tendre", 2) == "170 g de beurre tendre")
        #expect(scaled("150 g de farine", 1.5) == "225 g de farine")
        #expect(scaled("50 cl de lait", 0.5) == "25 cl de lait")
        #expect(scaled("1 oeuf", 3) == "3 oeufs")
        #expect(scaled("1,5 l d'eau", 2) == "3 l d'eau")
        #expect(scaled("2 x 200 g de chocolat", 2) == "4 x 200 g de chocolat")
    }

    @Test func frenchPluralsFollowTheQuantity() {
        #expect(scaled("1 cuillère à café de levure", 2) == "2 cuillères à café de levure")
        #expect(scaled("1 bonne pincée de sel", 2) == "2 bonnes pincées de sel")
        #expect(scaled("1 sachet de sucre vanillé", 3) == "3 sachets de sucre vanillé")
        #expect(scaled("1 gros oignon", 2) == "2 gros oignons")
        #expect(scaled("1 pomme", 4) == "4 pommes")
        #expect(scaled("4 oeufs", 0.25) == "1 oeuf")                          // back to the singular under 2
        #expect(scaled("3 gousses d'ail", 0.5) == "1 ½ gousse d'ail")
        #expect(scaled("2 cuillères à soupe d'huile", 2) == "4 cuillères à soupe d'huile")     // already plural: unchanged
        #expect(scaled("85 g de beurre", 3) == "255 g de beurre")             // units never change
        #expect(scaled("2 c. à soupe de sucre", 2) == "4 c. à soupe de sucre")
        #expect(scaled("2 pois chiches", 0.5) == "1 pois chiches")             // "pois" is its own singular
        #expect(scaled("1 gâteau", 2) == "2 gâteaux")
    }

    @Test func fractionsAreReadAndWritten() {
        #expect(scaled("1/2 citron", 1) == "½ citron")
        #expect(scaled("1/2 citron", 3) == "1 ½ citron")
        #expect(scaled("1 1/2 tasse de sucre", 2) == "3 tasses de sucre")
        #expect(scaled("½ cuillère à café", 2) == "1 cuillère à café")
        #expect(scaled("1 cuillère à soupe d'huile", 0.5) == "½ cuillère à soupe d'huile")
        #expect(scaled("1 sachet", 4.0 / 3) == "1 ⅓ sachet")
    }

    @Test func linesWithoutAQuantityOrWithARangeAreLeftAlone() {
        #expect(scaled("du sel", 4) == "du sel")
        #expect(scaled("vanille ou 1 sachet de sucre vanillé", 2) == "vanille ou 1 sachet de sucre vanillé")
        #expect(scaled("2 à 3 pommes", 2) == "2 à 3 pommes")
        #expect(scaled("2-3 pommes", 2) == "2-3 pommes")
        #expect(scaled("", 2) == "")
    }

    @Test func numbersAreRoundedForReading() {
        #expect(IngredientScaler.format(240) == "240")
        #expect(IngredientScaler.format(12.4) == "12")
        #expect(IngredientScaler.format(2.4) == "2,4")
        #expect(IngredientScaler.format(0.25) == "¼")
        #expect(IngredientScaler.format(2.999) == "3")
        #expect(IngredientScaler.format(0) == "0")
    }

    @Test func theTableHoldsEveryServingCountAndTheOriginalAtTheBase() {
        let lines = ["85 g de beurre", "du sel"]
        let table = IngredientScaler.table(for: lines, base: 4, maximum: 12)
        #expect(table.count == 12)
        #expect(table[3] == lines)                                          // 4 servings = the page's own text
        #expect(table[7] == ["170 g de beurre", "du sel"])
        #expect(table[0] == ["21 g de beurre", "du sel"])
        #expect(IngredientScaler.hasScalableLine(lines) && !IngredientScaler.hasScalableLine(["du sel", "poivre"]))
    }
}
