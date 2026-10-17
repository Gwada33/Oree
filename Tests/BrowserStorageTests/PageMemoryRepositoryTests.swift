import Testing
import Foundation
@testable import BrowserStorage

@Suite struct PageMemoryRepositoryTests {
    func repo() throws -> PageMemoryRepository {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pagememory-\(UUID().uuidString).sqlite")
        return PageMemoryRepository(database: try AppDatabase(path: url.path))
    }

    @Test func findsAPageByWordsAndGivesAnExcerpt() throws {
        let memory = try repo()
        try memory.remember(url: "https://a.fr/webkit", host: "a.fr", title: "La mémoire de WebKit", text: "Les processus WebContent partagent la mémoire des onglets d'un même site ; la veille la libère.")
        try memory.remember(url: "https://b.fr/cuisine", host: "b.fr", title: "Ratatouille", text: "Une recette de ratatouille avec des courgettes.")
        let hits = try memory.search(words: ["memoire", "webkit"].map { $0 })
        #expect(hits.map(\.host) == ["a.fr"])
        #expect(hits.first?.snippet.isEmpty == false)
        #expect(try memory.search(words: ["inconnu"]).isEmpty)
    }
    @Test func readingAgainUpdatesInsteadOfDuplicating() throws {
        let memory = try repo()
        try memory.remember(url: "https://a.fr/x", host: "a.fr", title: "Un", text: "alpha beta gamma")
        try memory.remember(url: "https://a.fr/x", host: "a.fr", title: "Deux", text: "alpha delta")
        #expect(try memory.count() == 1 && (try memory.search(words: ["delta"])).first?.title == "Deux")
    }
    @Test func forgetAndPurge() throws {
        let memory = try repo()
        let old = Date().addingTimeInterval(-40 * 86_400)
        try memory.remember(url: "https://a.fr/1", host: "a.fr", title: "Ancien", text: "contenu ancien", at: old)
        try memory.remember(url: "https://b.fr/2", host: "b.fr", title: "Récent", text: "contenu récent")
        try memory.purge(olderThanDays: 30)
        #expect(try memory.count() == 1)
        try memory.forget(host: "b.fr"); #expect(try memory.count() == 0)
        try memory.remember(url: "https://c.fr/3", host: "c.fr", title: "C", text: "x y z"); try memory.forgetAll(); #expect(try memory.count() == 0)
    }
}
