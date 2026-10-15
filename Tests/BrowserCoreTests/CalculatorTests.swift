import Testing
import Foundation
@testable import BrowserCore

@Suite struct CalculatorTests {
    private func calc(_ s: String) -> String? { Calculator.evaluate(s).map(Calculator.format) }

    @Test func basicArithmeticFollowsPrecedence() {
        #expect(calc("12*3+4") == "40")
        #expect(calc("2+3*4") == "14")
        #expect(calc("(2+3)*4") == "20")
        #expect(calc("100/8") == "12,5")
        #expect(calc("10-4-3") == "3")                   // left to right
        #expect(calc("2^3^2") == "512")                  // powers go right to left
        #expect(calc("-3+5") == "2")
        #expect(calc("2*-3") == "-6")
    }

    @Test func frenchWritingIsUnderstood() {
        #expect(calc("1,5 + 2,25") == "3,75")
        #expect(calc("6 × 7") == "42")
        #expect(calc("84 ÷ 2") == "42")
        #expect(calc("200 + 10%") == "200,1")            // % is "divide by 100", plainly
        #expect(calc("50%*2") == "1")
    }

    @Test func thingsThatAreNotCalculationsAreLeftAlone() {
        #expect(calc("2024") == nil)                      // a number, not a calculation
        #expect(calc("3.14") == nil)
        #expect(calc("-5") == nil)
        #expect(calc("recette 2+2") == nil)               // words
        #expect(calc("https://a.fr/b-c") == nil)
        #expect(calc("1/0") == nil)
        #expect(calc("2+") == nil)
        #expect(calc("(2+3") == nil)
        #expect(calc("1..2+3") == nil)
        #expect(calc("") == nil)
    }

    @Test func absurdInputIsRefusedAndNeverCrashes() {
        #expect(calc("9^9^9") == nil)
        #expect(calc("10^400") == nil)
        #expect(calc(String(repeating: "(", count: 500) + "1" + String(repeating: ")", count: 500) + "+1") == nil)    // too long
        #expect(calc(String(repeating: "9", count: 30) + "*9") == nil)                                                // too big
    }

    @Test func resultsAreFormattedWithTheFrenchComma() {
        #expect(Calculator.format(42) == "42")
        #expect(Calculator.format(0.1 + 0.2) == "0,3")
        #expect(Calculator.format(1.0 / 3.0) == "0,3333333333")
        #expect(Calculator.format(-2.5) == "-2,5")
        #expect(Calculator.format(1_000_000) == "1000000")
    }
}
