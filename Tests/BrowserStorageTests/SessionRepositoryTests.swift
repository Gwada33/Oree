import Testing
import Foundation
@testable import BrowserStorage

struct SessionRepositoryTests {
    private func makeTestDatabase() throws -> (database: AppDatabase, cleanup: () -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HyperBrowserTests-\(UUID().uuidString).sqlite")
        let database = try AppDatabase(path: url.path)
        return (database, { try? FileManager.default.removeItem(at: url) })
    }

    @Test func saveAndLoadRoundTripsOrderAndState() throws {
        let (database, cleanup) = try makeTestDatabase()
        defer { cleanup() }
        let repo = SessionRepository(database: database)

        let state = "fake-interaction-state".data(using: .utf8)
        try repo.save([
            TabSnapshot(orderIndex: 1, url: "https://b.example.com", isPrivate: false, interactionState: nil),
            TabSnapshot(orderIndex: 0, url: "https://a.example.com", isPrivate: false, interactionState: state),
        ])

        let loaded = try repo.load()
        #expect(loaded.map(\.url) == ["https://a.example.com", "https://b.example.com"], "must come back ordered by orderIndex")
        #expect(loaded.first?.interactionState == state)
    }

    @Test func privateTabsAreNeverSaved() throws {
        let (database, cleanup) = try makeTestDatabase()
        defer { cleanup() }
        let repo = SessionRepository(database: database)

        try repo.save([
            TabSnapshot(orderIndex: 0, url: "https://public.example.com", isPrivate: false, interactionState: nil),
            TabSnapshot(orderIndex: 1, url: "https://secret.example.com", isPrivate: true, interactionState: nil),
        ])

        let loaded = try repo.load()
        #expect(loaded.map(\.url) == ["https://public.example.com"])
    }

    @Test func saveReplacesThePreviousSessionWholesale() throws {
        let (database, cleanup) = try makeTestDatabase()
        defer { cleanup() }
        let repo = SessionRepository(database: database)

        try repo.save([TabSnapshot(orderIndex: 0, url: "https://old.example.com", isPrivate: false, interactionState: nil)])
        try repo.save([TabSnapshot(orderIndex: 0, url: "https://new.example.com", isPrivate: false, interactionState: nil)])

        #expect(try repo.load().map(\.url) == ["https://new.example.com"])
    }

    @Test func titlesSurviveSaveAndLoad() throws {
        let (database, cleanup) = try makeTestDatabase()
        defer { cleanup() }
        let repo = SessionRepository(database: database)
        try repo.save([TabSnapshot(orderIndex: 0, url: "https://a.example.com", isPrivate: false, interactionState: nil, title: "Titre A")])
        #expect(try repo.load().first?.title == "Titre A")
    }

    @Test func spacesSurviveSaveAndLoad() throws {
        let (database, cleanup) = try makeTestDatabase()
        defer { cleanup() }
        let repo = SessionRepository(database: database)
        try repo.save([
            TabSnapshot(orderIndex: 0, url: "https://a.example.com", isPrivate: false, interactionState: nil, spaceIndex: 2),
            TabSnapshot(orderIndex: 1, url: "https://b.example.com", isPrivate: false, interactionState: nil),
        ])
        #expect(try repo.load().map(\.spaceIndex) == [2, 0])
    }
}
