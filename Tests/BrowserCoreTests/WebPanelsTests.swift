import Foundation
import Testing
@testable import BrowserCore

@Suite("Panneaux web")
struct WebPanelsTests {
    @Test("ce qu'on tape devient une adresse web, sinon rien")
    func normalize() {
        #expect(WebPanels.normalize("notion.so")?.absoluteString == "https://notion.so")
        #expect(WebPanels.normalize("  https://web.whatsapp.com/ ")?.host == "web.whatsapp.com")
        #expect(WebPanels.normalize("http://localhost.test") != nil)
        #expect(WebPanels.normalize("") == nil)
        #expect(WebPanels.normalize("deux mots") == nil)
        #expect(WebPanels.normalize("ftp://exemple.fr") == nil)
        #expect(WebPanels.normalize("javascript:alert(1)") == nil)
        #expect(WebPanels.normalize("localhost") == nil)
    }

    @Test("un nom lisible depuis l'adresse")
    func names() {
        #expect(WebPanels.defaultName(for: URL(string: "https://web.whatsapp.com/")!) == "Whatsapp")
        #expect(WebPanels.defaultName(for: URL(string: "https://www.notion.so/")!) == "Notion")
        #expect(WebPanels.defaultName(for: URL(string: "https://calendar.google.com/")!) == "Google")
    }

    @Test("pas de doublon d'adresse, plafonné")
    func adding() {
        var list = [WebPanelEntry(name: "A", url: "https://a.test/")]
        list = WebPanels.adding(WebPanelEntry(name: "A2", url: "https://a.test/"), to: list)
        #expect(list == [WebPanelEntry(name: "A2", url: "https://a.test/")])
        for i in 0..<30 { list = WebPanels.adding(WebPanelEntry(name: "\(i)", url: "https://x\(i).test/"), to: list) }
        #expect(list.count == WebPanels.limit)
    }
}
