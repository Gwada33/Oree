import Testing
import Foundation
@testable import BrowserCore

@Suite struct ReaderPageTests {
    private func article(_ length: Int = 5000, title: String = "Un titre") -> ReaderArticle {
        ReaderArticle(title: title, byline: "Marie", site: "exemple.fr", contentHTML: "<p>Bonjour</p>", textLength: length, originalURL: "https://exemple.fr/a")
    }

    @Test func readabilityDependsOnTheLengthOfTheText() {
        #expect(article(5000).isReadable)
        #expect(!article(599).isReadable)
        #expect(article(600).isReadable)
    }

    @Test func readingTimeIsRoundedAndNeverZero() {
        #expect(article(10).minutes == 1)
        #expect(article(6 * 220 * 5).minutes == 5)
    }

    @Test func parsesTheScriptAnswer() throws {
        let json = #"{"title":"T","byline":"B","site":"S","html":"<p>x</p>","length":1234}"#
        let parsed = try #require(ReaderArticle.parse(json, originalURL: "https://a.example"))
        #expect(parsed.title == "T" && parsed.byline == "B" && parsed.textLength == 1234 && parsed.originalURL == "https://a.example")
        #expect(ReaderArticle.parse("nope", originalURL: "x") == nil)
        #expect(ReaderArticle.parse(#"{"title":"T"}"#, originalURL: "x") == nil)         // no content
    }

    @Test func thePageForbidsScriptsAndEscapesTheTitle() {
        let page = ReaderPage.html(article(title: "<script>alert(1)</script> & co"))
        #expect(page.contains("default-src 'none'"))
        #expect(!page.contains("<script>alert"))
        #expect(page.contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; co"))
        #expect(page.contains("<p>Bonjour</p>"))
        #expect(page.contains("Page d’origine"))
        #expect(page.contains("5 min de lecture") || page.contains("min de lecture"))
    }

    @Test func onlyWebAddressesBecomeTheOriginLink() {
        var a = article(); a.originalURL = "javascript:alert(1)"
        #expect(!ReaderPage.html(a).contains("javascript:"))
    }
}
