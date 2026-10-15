import Testing
import Foundation
@testable import BrowserCore

@Suite struct BookmarkExportTests {
    @Test func writesTheFormatBrowsersImport() {
        let html = BookmarkExport.html([
            BookmarkExport.Item(title: "Lisbonne — Wikipédia", url: "https://fr.wikipedia.org/wiki/Lisbonne", folder: "Perso", added: Date(timeIntervalSince1970: 1_700_000_000)),
            BookmarkExport.Item(title: "Swift", url: "https://swift.org/?a=1&b=2", folder: "Travail"),
        ])
        #expect(html.hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
        #expect(html.contains("<DT><H3>Perso</H3>") && html.contains("<DT><H3>Travail</H3>"))
        #expect(html.contains("<A HREF=\"https://fr.wikipedia.org/wiki/Lisbonne\" ADD_DATE=\"1700000000\">Lisbonne — Wikipédia</A>"))
        #expect(html.contains("HREF=\"https://swift.org/?a=1&amp;b=2\""))
    }

    @Test func escapesTitlesAndSkipsAddressesThatAreNotTheWeb() {
        let html = BookmarkExport.html([
            BookmarkExport.Item(title: "<script>x</script> & \"q\"", url: "https://a.example", folder: "F"),
            BookmarkExport.Item(title: "bad", url: "javascript:alert(1)", folder: "F"),
            BookmarkExport.Item(title: "local", url: "file:///etc/passwd", folder: "F"),
        ])
        #expect(html.contains("&lt;script&gt;x&lt;/script&gt; &amp; &quot;q&quot;"))
        #expect(!html.contains("javascript:") && !html.contains("file://"))
    }

    @Test func aBookmarkWithoutTitleShowsItsAddressAndAnEmptyListIsStillAFile() {
        #expect(BookmarkExport.html([BookmarkExport.Item(title: "", url: "https://a.example", folder: "F")]).contains(">https://a.example</A>"))
        let empty = BookmarkExport.html([])
        #expect(empty.contains("<DL><p>") && !empty.contains("<A "))
    }
}
