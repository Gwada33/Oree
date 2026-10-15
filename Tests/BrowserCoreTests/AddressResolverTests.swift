import Testing
import Foundation
@testable import BrowserCore

@Suite struct AddressResolverTests {
    private func resolve(_ text: String, custom: [SearchShortcut] = []) -> AddressResolution? {
        AddressResolver.resolve(text, defaultEngine: .google, custom: custom)
    }

    @Test func addressesAreOpened() {
        #expect(resolve("example.com") == .address(URL(string: "https://example.com")!))
        #expect(resolve("https://example.com/a?b=1") == .address(URL(string: "https://example.com/a?b=1")!))
        #expect(resolve("localhost:3000/app") == .address(URL(string: "http://localhost:3000/app")!))
        #expect(resolve("192.168.1.1:8080") == .address(URL(string: "http://192.168.1.1:8080")!))
    }

    @Test func plainWordsAreSearchedWithTheDefaultEngine() throws {
        let result = try #require(resolve("recette de crêpes"))
        guard case .search(let site, let url) = result else { Issue.record("expected a search"); return }
        #expect(site == "Google")
        #expect(url.absoluteString == "https://www.google.com/search?q=recette%20de%20cr%C3%AApes")
    }

    @Test func theDefaultEngineIsRespected() {
        let result = AddressResolver.resolve("chat", defaultEngine: .duckduckgo)
        #expect(result == .search(site: "DuckDuckGo", url: URL(string: "https://duckduckgo.com/?q=chat")!))
    }

    @Test func aKeywordSendsTheWordsToThatSite() {
        #expect(resolve("w Lisbonne") == .search(site: "Wikipédia", url: URL(string: "https://fr.wikipedia.org/w/index.php?search=Lisbonne")!))
        #expect(resolve("YT  chats mignons") == .search(site: "YouTube", url: URL(string: "https://www.youtube.com/results?search_query=chats%20mignons")!))
    }

    @Test func aKeywordAloneIsJustASearchOrAnAddress() {
        // "w" with nothing after it is not a site search.
        #expect(resolve("w") == resolve("w"))
        guard case .search(let site, _) = resolve("w")! else { Issue.record("expected a search"); return }
        #expect(site == "Google")
    }

    @Test func specialCharactersCannotBreakTheQuery() throws {
        let result = try #require(resolve("a&b=c+d#e"))
        #expect(result.url.absoluteString == "https://www.google.com/search?q=a%26b%3Dc%2Bd%23e")
    }

    @Test func customShortcutsWinOverBuiltIns() {
        let mine = SearchShortcut(name: "Mon wiki", keyword: "w", template: "https://wiki.example/?s=%s")
        #expect(resolve("w chose", custom: [mine]) == .search(site: "Mon wiki", url: URL(string: "https://wiki.example/?s=chose")!))
    }

    @Test func invalidCustomShortcutsAreIgnored() {
        let broken = SearchShortcut(name: "X", keyword: "zz", template: "pas une adresse %s")
        #expect(!broken.isValid)
        guard case .search(let site, _) = resolve("zz mot", custom: [broken])! else { Issue.record("expected a search"); return }
        #expect(site == "Google")
        #expect(!SearchShortcut(name: "", keyword: "k", template: "https://x/%s").isValid)
        #expect(!SearchShortcut(name: "N", keyword: "a b", template: "https://x/%s").isValid)
        #expect(!SearchShortcut(name: "N", keyword: "k", template: "https://x/").isValid)          // no %s
        #expect(!SearchShortcut(name: "N", keyword: "k", template: "javascript:alert(%s)").isValid)
        #expect(SearchShortcut(name: "N", keyword: "k", template: "https://x/?q=%s").isValid)
    }

    @Test func emptyInputResolvesToNothing() {
        #expect(resolve("   ") == nil)
    }
}
