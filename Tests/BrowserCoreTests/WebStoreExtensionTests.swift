import Testing
import Foundation
@testable import BrowserCore

@Suite struct WebStoreExtensionTests {
    private let id = "cjpalhdlnbpafiamejdnhcphjbkeiagm"
    private func extract(_ s: String) -> String? { WebStoreExtension.id(from: URL(string: s)) }

    @Test func recognisesBothStoreAddresses() {
        #expect(extract("https://chromewebstore.google.com/detail/ublock-origin/\(id)") == id)
        #expect(extract("https://chromewebstore.google.com/detail/ublock-origin/\(id)?hl=fr") == id)
        #expect(extract("https://chrome.google.com/webstore/detail/ublock-origin/\(id)") == id)
    }

    @Test func ignoresEverythingElse() {
        #expect(extract("https://chromewebstore.google.com/") == nil)
        #expect(extract("https://chromewebstore.google.com/search/adblock") == nil)
        #expect(extract("https://evil.example/detail/x/\(id)") == nil)
        #expect(extract("http://chromewebstore.google.com/detail/x/\(id)") == nil)      // https only
        #expect(extract("https://chromewebstore.google.com/detail/x/NOTANID") == nil)
        #expect(extract("https://chromewebstore.google.com/detail/x/\(id.uppercased())") == nil)
    }

    @Test func packageAddressCarriesTheIdentifier() throws {
        let url = try #require(WebStoreExtension.packageURL(id: id))
        #expect(url.host == "clients2.google.com")
        #expect(url.absoluteString.contains("id%3D\(id)") || url.absoluteString.contains("id=\(id)"))
        #expect(WebStoreExtension.packageURL(id: "short") == nil)
    }

    @Test func nameDropsTheStoreSuffix() {
        #expect(WebStoreExtension.name(fromTitle: "uBlock Origin - Chrome Web Store") == "uBlock Origin")
        #expect(WebStoreExtension.name(fromTitle: nil) == "cette extension")
        #expect(WebStoreExtension.name(fromTitle: " - Chrome Web Store") == "cette extension")
    }
}
