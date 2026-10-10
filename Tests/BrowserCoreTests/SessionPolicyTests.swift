import Testing
import Foundation
@testable import BrowserCore

@Suite struct SessionPolicyTests {
    @Test func privateTabsAreNeverSaved() {
        #expect(!SessionPolicy.isSavable(url: URL(string: "https://example.com"), isPrivate: true))
        #expect(SessionPolicy.isSavable(url: URL(string: "https://example.com"), isPrivate: false))
    }

    @Test func blankAndOwnPagesAreSkipped() {
        #expect(!SessionPolicy.isSavable(url: nil, isPrivate: false))
        #expect(!SessionPolicy.isSavable(url: URL(string: "about:blank"), isPrivate: false))
        #expect(!SessionPolicy.isSavable(url: URL(string: "oree://home/"), isPrivate: false))
    }
}
