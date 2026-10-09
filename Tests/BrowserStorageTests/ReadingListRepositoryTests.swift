import Testing
import Foundation
@testable import BrowserStorage

struct ReadingListRepositoryTests {
    private func makeTestDatabase() throws -> (database: AppDatabase, cleanup: () -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HyperBrowserTests-\(UUID().uuidString).sqlite")
        let database = try AppDatabase(path: url.path)
        return (database, { try? FileManager.default.removeItem(at: url) })
    }

    @Test func addContainsRemove() throws {
        let (database, cleanup) = try makeTestDatabase(); defer { cleanup() }
        let repo = ReadingListRepository(database: database)
        try repo.add(url: "https://a.example", title: "A")
        #expect(try repo.contains(url: "https://a.example"))
        try repo.remove(url: "https://a.example")
        #expect(try !repo.contains(url: "https://a.example"))
    }

    @Test func readdingMovesToTopWithoutDuplicates() throws {
        let (database, cleanup) = try makeTestDatabase(); defer { cleanup() }
        let repo = ReadingListRepository(database: database)
        try repo.add(url: "https://a.example", title: "A")
        try repo.add(url: "https://b.example", title: "B")
        try repo.add(url: "https://a.example", title: "A2")
        let all = try repo.all()
        #expect(all.map(\.url) == ["https://a.example", "https://b.example"])
        #expect(all.first?.title == "A2")
    }
}
