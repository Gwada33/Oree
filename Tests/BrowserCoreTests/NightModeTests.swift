import Testing
import Foundation
@testable import BrowserCore

@Suite struct NightModeTests {
    @Test func modeDecidesWhenTheDarkeningIsOn() {
        #expect(!NightPolicy.isActive(mode: .off, appearanceIsDark: true))
        #expect(NightPolicy.isActive(mode: .auto, appearanceIsDark: true))
        #expect(!NightPolicy.isActive(mode: .auto, appearanceIsDark: false))
        #expect(NightPolicy.isActive(mode: .always, appearanceIsDark: false))
    }

    @Test func aSiteListCoversSubdomainsAndWww() {
        let list = ["example.com"]
        #expect(NightPolicy.contains("www.example.com", in: list))
        #expect(NightPolicy.contains("news.example.com", in: list))
        #expect(!NightPolicy.contains("notexample.com", in: list))
        #expect(!NightPolicy.contains(nil, in: list))
    }

    @Test func addingIsNormalizedUniqueAndBounded() {
        var list = NightPolicy.adding("WWW.Example.com", to: [])
        #expect(list == ["example.com"])
        list = NightPolicy.adding("example.com", to: list)
        #expect(list == ["example.com"])
        for index in 0..<10 { list = NightPolicy.adding("site\(index).com", to: list, limit: 4) }
        #expect(list == ["site6.com", "site7.com", "site8.com", "site9.com"])      // the oldest go first
        #expect(NightPolicy.removing("www.site7.com", from: list) == ["site6.com", "site8.com", "site9.com"])
    }
}
