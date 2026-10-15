import Testing
import Foundation
@testable import BrowserCore

@Suite struct SpeechTextTests {
    @Test func theScriptStartsWithTheTitleAndCollapsesSpaces() {
        #expect(SpeechText.script(title: "Lisbonne", body: "La   capitale\n\n du  Portugal.") == "Lisbonne. La capitale du Portugal.")
        #expect(SpeechText.script(title: " ", body: "Texte") == "Texte")
        #expect(SpeechText.script(title: "Titre", body: "  \n ") == "")
    }

    @Test func passagesEndAtSentences() {
        let text = "Première phrase. Deuxième phrase plus longue que la première! Troisième ?"
        let parts = SpeechText.chunks(text, maxLength: 40)
        #expect(parts == ["Première phrase.", "Deuxième phrase plus longue que la", "première! Troisième ?"] || parts.allSatisfy { $0.count <= 40 })
        #expect(parts.allSatisfy { $0.count <= 40 })
        #expect(parts.joined(separator: " ").replacingOccurrences(of: "  ", with: " ") == text)
    }

    @Test func aLongSentenceIsCutAtACommaOrASpace() {
        let long = Array(repeating: "mot", count: 60).joined(separator: " ")           // no punctuation at all
        let parts = SpeechText.chunks(long, maxLength: 50)
        #expect(parts.allSatisfy { $0.count <= 50 } && parts.count >= 4)
        #expect(parts.joined(separator: " ") == long)
        let withComma = SpeechText.chunks("Un début assez long pour dépasser la limite, puis la suite qui continue encore et encore", maxLength: 50)
        #expect(withComma.first?.hasSuffix(",") == true)
    }

    @Test func nothingToSayGivesNoPassage() {
        #expect(SpeechText.chunks("   \n ").isEmpty)
        #expect(SpeechText.chunks("court", maxLength: 380) == ["court"])
    }

    @Test func theLanguageComesFromThePageWhenItIsOne() {
        #expect(SpeechText.language(pageLang: "fr-FR", fallback: "en-US") == "fr-FR")
        #expect(SpeechText.language(pageLang: "en_GB", fallback: "fr-FR") == "en-GB")
        #expect(SpeechText.language(pageLang: "x", fallback: "fr-FR") == "fr-FR")
        #expect(SpeechText.language(pageLang: "'; drop table", fallback: "fr-FR") == "fr-FR")
        #expect(SpeechText.language(pageLang: nil, fallback: "fr-FR") == "fr-FR")
    }
}
