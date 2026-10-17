import Testing
import Foundation
@testable import BrowserCore

@Suite struct PageMemoryPolicyTests {
    let article = String(repeating: "WebKit gère la mémoire des onglets autrement que Chrome. ", count: 20)
    func keep(_ url: String, text: String? = nil, isPrivate: Bool = false, secret: Bool = false, exempt: [String] = []) -> PageMemoryPolicy.Page? {
        PageMemoryPolicy.memorable(url: URL(string: url), title: "Titre", text: text ?? article, isPrivate: isPrivate, hasSecretField: secret, exemptHosts: exempt)
    }
    @Test func keepsAnOrdinaryArticleWithoutItsQueryOrFragment() {
        let page = keep("https://blog.exemple.fr/webkit-memoire?utm=1&token=secret#partie-2")
        #expect(page?.url.absoluteString == "https://blog.exemple.fr/webkit-memoire")
        #expect((page?.text.count ?? 0) <= PageMemoryPolicy.maximumCharacters)
    }
    @Test func neverKeepsPrivateSecretOrSensitivePages() {
        #expect(keep("https://blog.exemple.fr/a", isPrivate: true) == nil)
        #expect(keep("https://blog.exemple.fr/a", secret: true) == nil)
        #expect(keep("https://www.paypal.com/home") == nil && keep("https://mabanque.fr/accueil") == nil && keep("https://mail.google.com/mail") == nil)
        #expect(keep("https://exemple.fr/login") == nil && keep("https://exemple.fr/checkout/step2") == nil && keep("https://exemple.fr/mon-compte") == nil)
        #expect(keep("https://blog.exemple.fr/a", exempt: ["exemple.fr"]) == nil)
        #expect(keep("file:///etc/hosts") == nil && keep("oree://settings") == nil)
    }
    @Test func skipsPagesWithTooLittleText() { #expect(keep("https://exemple.fr/court", text: "Trop court.") == nil) }
    @Test func keywordsDropFillerWords() {
        #expect(PageMemoryPolicy.keywords(from: "l'article sur la mémoire de WebKit que j'ai lu mardi") == ["memoire", "webkit"])
    }
}
