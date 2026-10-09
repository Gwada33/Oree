import Testing
import Foundation
@testable import BrowserStorage

struct BookmarkRepositoryTests {
    private func makeTestDatabase() throws -> (database: AppDatabase, cleanup: () -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HyperBrowserTests-\(UUID().uuidString).sqlite")
        let database = try AppDatabase(path: url.path)
        return (database, { try? FileManager.default.removeItem(at: url) })
    }

    @Test func addIsIdempotentPerURL() throws {
        let (database, cleanup) = try makeTestDatabase()
        defer { cleanup() }
        let repo = BookmarkRepository(database: database)
        try repo.add(url: "https://apple.com", title: "Apple")
        try repo.add(url: "https://apple.com", title: "Apple (duplicate attempt)")
        #expect(try repo.all().count == 1)
    }

    @Test func removeAndClear() throws {
        let (database, cleanup) = try makeTestDatabase()
        defer { cleanup() }
        let repo = BookmarkRepository(database: database)
        try repo.add(url: "https://apple.com", title: "Apple")
        try repo.add(url: "https://swift.org", title: "Swift")

        try repo.remove(url: "https://apple.com")
        #expect(try repo.all().map(\.url) == ["https://swift.org"])

        try repo.clear()
        #expect(try repo.all().isEmpty)
    }

    @Test func containsReflectsAddAndRemove() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HyperBrowserTests-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let repo = BookmarkRepository(database: try AppDatabase(path: url.path))
        #expect(try repo.contains(url: "https://a.com") == false)
        try repo.add(url: "https://a.com", title: "A")
        #expect(try repo.contains(url: "https://a.com"))
        try repo.remove(url: "https://a.com")
        #expect(try repo.contains(url: "https://a.com") == false)
    }
}
