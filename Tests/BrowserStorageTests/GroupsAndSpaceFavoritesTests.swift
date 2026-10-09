import Testing
import Foundation
import BrowserCore
@testable import BrowserStorage

struct GroupsAndSpaceFavoritesTests {
    private func makeTestDatabase() throws -> (database: AppDatabase, cleanup: () -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HyperBrowserTests-\(UUID().uuidString).sqlite")
        let database = try AppDatabase(path: url.path)
        return (database, { try? FileManager.default.removeItem(at: url) })
    }

    @Test func groupsRoundTripInOrder() throws {
        let (database, cleanup) = try makeTestDatabase()
        defer { cleanup() }
        let repo = TabGroupRepository(database: database)
        let a = TabGroup(name: "A", spaceIndex: 0), b = TabGroup(name: "B", spaceIndex: 1, collapsed: true)
        try repo.save([b, a])
        let loaded = try repo.load()
        #expect(loaded == [b, a])
    }

    @Test func tabGroupIDSurvivesSessionSave() throws {
        let (database, cleanup) = try makeTestDatabase()
        defer { cleanup() }
        let repo = SessionRepository(database: database)
        try repo.save([TabSnapshot(orderIndex: 0, url: "https://a.example", isPrivate: false, interactionState: nil, groupID: "G1")])
        #expect(try repo.load().first?.groupID == "G1")
    }

    @Test func favoritesAreFilteredBySpaceButSharedOnesShowEverywhere() throws {
        let (database, cleanup) = try makeTestDatabase()
        defer { cleanup() }
        let repo = BookmarkRepository(database: database)
        try repo.add(url: "https://shared.example", title: "Shared")
        try repo.add(url: "https://work.example", title: "Work", spaceIndex: 1)
        try repo.add(url: "https://home.example", title: "Home", spaceIndex: 0)
        #expect(Set(try repo.all(forSpace: 0).map(\.url)) == ["https://shared.example", "https://home.example"])
        #expect(Set(try repo.all(forSpace: 1).map(\.url)) == ["https://shared.example", "https://work.example"])
        #expect(try repo.all().count == 3)
    }
}

extension GroupsAndSpaceFavoritesTests {
    @Test func deletingASpaceReindexesFavorites() throws {
        let (database, cleanup) = try makeTestDatabase()
        defer { cleanup() }
        let repo = BookmarkRepository(database: database)
        try repo.add(url: "https://a.example", title: "A", spaceIndex: 0)
        try repo.add(url: "https://b.example", title: "B", spaceIndex: 1)
        try repo.add(url: "https://c.example", title: "C", spaceIndex: 2)
        try repo.reindex(afterDeletingSpace: 1)
        let all = try repo.all()
        func space(_ url: String) -> Int?? { all.first { $0.url == url }.map { $0.spaceIndex } }
        #expect(space("https://a.example") == .some(0))
        #expect(space("https://b.example") == .some(nil))   // became shared
        #expect(space("https://c.example") == .some(1))
    }
}
