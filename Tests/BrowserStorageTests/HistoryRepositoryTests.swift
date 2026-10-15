import Testing
import Foundation
@testable import BrowserStorage

struct HistoryRepositoryTests {
    private func makeTestDatabase() throws -> (database: AppDatabase, cleanup: () -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HyperBrowserTests-\(UUID().uuidString).sqlite")
        let database = try AppDatabase(path: url.path)
        return (database, { try? FileManager.default.removeItem(at: url) })
    }

    @Test func recordVisitInsertsThenIncrementsVisitCount() throws {
        let (database, cleanup) = try makeTestDatabase()
        defer { cleanup() }
        let repo = HistoryRepository(database: database)

        try repo.recordVisit(url: "https://apple.com", title: "Apple")
        var entries = try repo.recent()
        #expect(entries.count == 1)
        #expect(entries.first?.visitCount == 1)

        try repo.recordVisit(url: "https://apple.com", title: "Apple")
        entries = try repo.recent()
        #expect(entries.count == 1, "revisiting the same URL must not create a duplicate row")
        #expect(entries.first?.visitCount == 2)
    }

    /// This is the one that actually proves FTS5 is usable on the system
    /// SQLite build we link against — not a given on every Apple SQLite
    /// build, which is exactly why this needed a real runtime check.
    @Test func fullTextSearchFindsMatchingTitleAndURL() throws {
        let (database, cleanup) = try makeTestDatabase()
        defer { cleanup() }
        let repo = HistoryRepository(database: database)
        try repo.recordVisit(url: "https://www.apple.com", title: "Apple")
        try repo.recordVisit(url: "https://www.swift.org", title: "Swift Programming Language")
        try repo.recordVisit(url: "https://example.com", title: "Example Domain")

        let byTitle = try repo.search(matching: "Swift")
        #expect(byTitle.map(\.url) == ["https://www.swift.org"])

        let byURL = try repo.search(matching: "apple")
        #expect(byURL.map(\.url) == ["https://www.apple.com"])

        let noMatch = try repo.search(matching: "nonexistent")
        #expect(noMatch.isEmpty)
    }

    @Test func clearRemovesAllHistory() throws {
        let (database, cleanup) = try makeTestDatabase()
        defer { cleanup() }
        let repo = HistoryRepository(database: database)
        try repo.recordVisit(url: "https://apple.com", title: "Apple")
        try repo.clear()
        #expect(try repo.recent().isEmpty)
    }
}

extension HistoryRepositoryTests {
    @Test func addressesContainingTextComeMostVisitedFirstAndWildcardsAreLiteral() throws {
        let (database, cleanup) = try makeTestDatabase()
        defer { cleanup() }
        let repo = HistoryRepository(database: database)
        try repo.recordVisit(url: "https://github.com/a", title: "A")
        try repo.recordVisit(url: "https://github.io/b", title: "B")
        try repo.recordVisit(url: "https://github.io/b", title: "B")          // visited twice: first
        try repo.recordVisit(url: "https://exemple.fr/100%_fini", title: "C")
        #expect(try repo.addresses(containing: "github") == ["https://github.io/b", "https://github.com/a"])
        #expect(try repo.addresses(containing: "100%_") == ["https://exemple.fr/100%_fini"])
        #expect(try repo.addresses(containing: "%").count == 1)                // "%" alone is a character, not "everything"
        #expect(try repo.addresses(containing: "zzz").isEmpty)
    }
}
