import Testing
import Foundation
@testable import BrowserCore

@Suite struct MarkdownTests {
    @Test func blocks() {
        let source = "# Titre\nUn *peu* de **texte**\nsur deux lignes.\n\n- un\n- deux\n\n1. a\n2. b\n\n> citation\n\n```\nlet x = 1\n```\n\n---\n\n| Nom | Prix |\n|---|---:|\n| Casque | 89 € |\n| Câble | 9 € |"
        #expect(Markdown.parse(source) == [
            .heading(level: 1, text: "Titre"), .paragraph("Un *peu* de **texte** sur deux lignes."),
            .list(items: ["un", "deux"], ordered: false), .list(items: ["a", "b"], ordered: true),
            .quote("citation"), .code("let x = 1"), .rule,
            .table(header: ["Nom", "Prix"], rows: [["Casque", "89 €"], ["Câble", "9 €"]]),
        ])
    }

    @Test func inlineMarks() {
        #expect(Markdown.spans("a **b** *c* `d` [e](https://x.fr)") == [.text("a "), .bold("b"), .text(" "), .italic("c"), .text(" "), .code("d"), .text(" "), .link(text: "e", url: URL(string: "https://x.fr")!)])
        #expect(Markdown.spans("2 * 3 = 6 et snake_case") == [.text("2 * 3 = 6 et snake_case")])         // pas de marque refermée : du texte
        #expect(Markdown.spans("**non fermé") == [.text("**non fermé")])
        #expect(Markdown.plainText("**gras** et [lien](https://x.fr)") == "gras et lien")
    }

    @Test func nothingIsEverInterpretedAsHTMLOrScript() {
        let html = Markdown.page(title: "<b>t</b>", source: "<script>alert(1)</script> [clic](javascript:alert(1)) [ok](https://a.fr)\n\n```\n<img src=x onerror=alert(1)>\n```")
        #expect(!html.contains("<script>alert") && !html.contains("<img src=x"))
        #expect(!html.contains("href=\"javascript"))
        #expect(html.contains("href=\"https://a.fr\"") && html.contains("&lt;script&gt;"))
        #expect(html.contains("Content-Security-Policy"))
    }

    @Test func unclosedCodeFenceRunsToTheEnd() {
        #expect(Markdown.parse("```\nabc\ndef") == [.code("abc\ndef")])
    }

    @Test func emptyInputGivesNothing() { #expect(Markdown.parse("").isEmpty && Markdown.parse("\n\n").isEmpty) }
}
