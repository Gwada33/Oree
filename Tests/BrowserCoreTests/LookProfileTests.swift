import Testing
import Foundation
@testable import BrowserCore

@Suite struct LookProfileTests {
    @Test func codableRoundTrip() throws {
        let profile = LookProfile.builtIn[1]
        let data = try JSONEncoder().encode([profile])
        #expect(try JSONDecoder().decode([LookProfile].self, from: data) == [profile])
    }

    @Test func builtInNamesAreUniqueAndValid() {
        #expect(Set(LookProfile.builtIn.map(\.name)).count == LookProfile.builtIn.count)
        #expect(LookProfile.builtIn.allSatisfy { (0...16).contains($0.radius) && (-1...1).contains($0.textOffset) })
    }

    @Test func sameLookIgnoresName() {
        var other = LookProfile.builtIn[0]; other.name = "Autre"
        #expect(LookProfile.builtIn[0].sameLook(as: other))
        other.radius = 2
        #expect(!LookProfile.builtIn[0].sameLook(as: other))
    }
}
