import Testing
import Foundation
@testable import BrowserCore

@Suite struct CopyPolicyTests {
    @Test func aCopiedAddressIsRecognized() {
        #expect(CopyPolicy.postalAddress(in: "12 rue de Rivoli, 75001 Paris") != nil)
        #expect(CopyPolicy.postalAddress(in: "  1 Infinite Loop\nCupertino, CA 95014  ") == "1 Infinite Loop\nCupertino, CA 95014")
    }

    @Test func aSentenceMentioningAnAddressIsNot() {
        #expect(CopyPolicy.postalAddress(in: "Rendez-vous demain à 14h devant le cinéma, on mangera ensuite quelque part en ville.") == nil)
        #expect(CopyPolicy.postalAddress(in: "Meet me at 1 Infinite Loop, Cupertino, CA 95014 tomorrow at six, bring the documents and the keys please") == nil)
        #expect(CopyPolicy.postalAddress(in: "42") == nil)
    }

    @Test func aLongTextIsNeverAnAddress() {
        let long = String(repeating: "12 rue de Rivoli, 75001 Paris ", count: 10)
        #expect(CopyPolicy.postalAddress(in: long) == nil)
        #expect(CopyPolicy.postalAddress(in: "a\nb\nc\nd\n12 rue de Rivoli, 75001 Paris") == nil)
    }

    @Test func mapsLinkKeepsTheWholeAddress() throws {
        let url = try #require(CopyPolicy.mapsURL(for: "12 rue de Rivoli\n75001 Paris & co"))
        #expect(url.scheme == "maps")
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value)
        #expect(query == "12 rue de Rivoli, 75001 Paris & co")
    }
}
