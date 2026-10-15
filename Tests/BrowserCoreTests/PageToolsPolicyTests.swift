import Testing
import Foundation
@testable import BrowserCore

@Suite struct PageToolsPolicyTests {
    @Test func pdfNameKeepsTheTitleAndDropsForbiddenCharacters() {
        #expect(PageToolsPolicy.pdfFileName(title: "Lisbonne — Wikipédia", host: "fr.wikipedia.org") == "Lisbonne — Wikipédia.pdf")
        #expect(PageToolsPolicy.pdfFileName(title: "a/b:c*d?e\"f<g>h|i", host: nil) == "a b c d e f g h i.pdf")
    }

    @Test func pdfNameFallsBackOnTheHostThenOnPage() {
        #expect(PageToolsPolicy.pdfFileName(title: "  ", host: "example.com") == "example.com.pdf")
        #expect(PageToolsPolicy.pdfFileName(title: nil, host: nil) == "Page.pdf")
        #expect(PageToolsPolicy.pdfFileName(title: "///", host: "") == "Page.pdf")
    }

    @Test func pdfNameIsBounded() {
        let name = PageToolsPolicy.pdfFileName(title: String(repeating: "x", count: 500), host: nil)
        #expect(name.count == 104)          // 100 characters + ".pdf"
    }

    @Test func sourceIsShownNotRun() {
        let page = PageToolsPolicy.sourcePage(html: "<script>alert(1)</script>\n<p>a & b</p>", address: "https://x.example/?a=1&b=\"2\"")
        #expect(!page.contains("<script>alert"))
        #expect(page.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(page.contains("a &amp; b"))
        #expect(page.contains("<span class=n>2</span>"))                       // line numbers
        #expect(page.contains("https://x.example/?a=1&amp;b=&quot;2&quot;"))   // the address in the title is escaped too
    }
}

extension PageToolsPolicyTests {
    @Test func slicesCoverThePageAndStopAtTheCap() {
        let slices = PageToolsPolicy.pdfSlices(contentHeight: 5000, sliceHeight: 2400, maxSlices: 40)
        #expect(slices.count == 3 && slices[0].origin == 0 && slices[2].origin == 4800 && slices[2].height == 200)
        #expect(PageToolsPolicy.pdfSlices(contentHeight: 1_000_000, sliceHeight: 2400, maxSlices: 40).count == 40)   // never an unbounded file
        #expect(PageToolsPolicy.pdfSlices(contentHeight: 0, sliceHeight: 2400, maxSlices: 40).count == 1)
        #expect(PageToolsPolicy.pdfSlices(contentHeight: .nan, sliceHeight: 2400, maxSlices: 40).count == 1)
    }
}
