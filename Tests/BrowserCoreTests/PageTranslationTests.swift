import Testing
import Foundation
@testable import BrowserCore

@Suite struct PageTranslationTests {
    @Test func onlyWebPagesAreTranslatable() {
        #expect(TranslationPolicy.canTranslate(url: URL(string: "https://example.com/a")))
        #expect(TranslationPolicy.canTranslate(url: URL(string: "HTTP://example.com")))
        #expect(!TranslationPolicy.canTranslate(url: URL(string: "oree://start")))
        #expect(!TranslationPolicy.canTranslate(url: URL(string: "file:///tmp/a.html")))
        #expect(!TranslationPolicy.canTranslate(url: nil))
    }

    @Test func primaryLanguageIgnoresRegionAndScript() {
        #expect(TranslationPolicy.primary("fr-CA") == "fr")
        #expect(TranslationPolicy.primary("pt_BR") == "pt")
        #expect(TranslationPolicy.primary("zh-Hans-CN") == "zh")
        #expect(TranslationPolicy.primary("EN") == "en")
        #expect(TranslationPolicy.primary("") == "")
    }

    @Test func offerOnlyWhenTheLanguageClearlyDiffers() {
        #expect(TranslationPolicy.shouldOffer(pageLanguage: "en", targetLanguage: "fr-FR"))
        #expect(!TranslationPolicy.shouldOffer(pageLanguage: "fr-BE", targetLanguage: "fr-FR"))
        #expect(!TranslationPolicy.shouldOffer(pageLanguage: nil, targetLanguage: "fr"))
        #expect(!TranslationPolicy.shouldOffer(pageLanguage: "und", targetLanguage: "fr"))
        #expect(!TranslationPolicy.shouldOffer(pageLanguage: "en", targetLanguage: ""))
    }

    @Test func textWithoutLettersIsLeftAlone() {
        #expect(TranslationPolicy.isTranslatable("Sign in"))
        #expect(TranslationPolicy.isTranslatable("日本語"))
        #expect(!TranslationPolicy.isTranslatable("12,99 €"))
        #expect(!TranslationPolicy.isTranslatable("— · —"))
    }

    @Test func roundAsksTheModelOnceForRepeatedText() {
        var memory = TranslationMemory()
        memory.store("Connexion", for: "Sign in")
        let round = TranslationRound(segments: [
            .init(id: 1, text: "Read more"), .init(id: 2, text: "Sign in"), .init(id: 3, text: "Read more"),
            .init(id: 4, text: "42"), .init(id: 5, text: "Share"),
        ], memory: memory)
        #expect(round.pending == ["Read more", "Share"])               // first-appearance order, no repeat
        #expect(round.waiting["Read more"] == [1, 3])                   // both places get the one answer
        #expect(round.known.map(\.id) == [2, 4])
        #expect(round.known.map(\.text) == ["Connexion", "42"])         // memory hit, and the number settled as is
    }

    @Test func memoryIsBounded() {
        var memory = TranslationMemory(limit: 3)
        for index in 0..<10 { memory.store("t\(index)", for: "s\(index)") }
        #expect(memory.count <= 3)
        #expect(memory["s9"] == "t9")                                   // the newest entry always survives
    }
}
