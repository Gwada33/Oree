import Testing
import Foundation
@testable import BrowserStorage

struct SuggestionProviderTests {
    private func makeTestDatabase() throws -> (database: AppDatabase, cleanup: () -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HyperBrowserTests-\(UUID().uuidString).sqlite")
        let database = try AppDatabase(path: url.path)
        return (database, { try? FileManager.default.removeItem(at: url) })
    }

    @Test func frequentlyVisitedSiteRanksAboveOneOffVisit() throws {
        let (database, cleanup) = try makeTestDatabase()
        defer { cleanup() }
        let history = HistoryRepository(database: database)
        for _ in 0..<10 {
            try history.recordVisit(url: "https://news.ycombinator.com", title: "Hacker News")
        }
        try history.recordVisit(url: "https://news-unrelated.example.com", title: "News unrelated")

        let provider = SuggestionProvider(database: database)
        let results = try provider.suggestions(for: "news")

        #expect(results.first?.url == "https://news.ycombinator.com")
    }

    @Test func suggestionFlagsBookmarkedURLs() throws {
        let (database, cleanup) = try makeTestDatabase()
        defer { cleanup() }
        let history = HistoryRepository(database: database)
        let bookmarks = BookmarkRepository(database: database)

        try history.recordVisit(url: "https://apple.com", title: "Apple")
        try bookmarks.add(url: "https://apple.com", title: "Apple")

        let results = try SuggestionProvider(database: database).suggestions(for: "apple")
        #expect(results.first?.isBookmarked == true)
    }
}
