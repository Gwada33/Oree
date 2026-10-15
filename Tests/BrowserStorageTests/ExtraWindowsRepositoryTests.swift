import Testing
import Foundation
@testable import BrowserStorage

struct ExtraWindowsRepositoryTests {
    private func makeRepo() throws -> (ExtraWindowsRepository, () -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ExtraWindows-\(UUID().uuidString).sqlite")
        return (ExtraWindowsRepository(database: try AppDatabase(path: url.path)), { try? FileManager.default.removeItem(at: url) })
    }

    private func tab(_ url: String, active: Bool = false, space: Int = 0) -> ExtraWindowTab {
        ExtraWindowTab(url: url, interactionState: Data([1, 2, 3]), title: "t", spaceIndex: space, isActive: active)
    }

    @Test func windowsAndTabsComeBackInOrder() throws {
        let (repo, cleanup) = try makeRepo(); defer { cleanup() }
        try repo.save([[tab("https://a.example"), tab("https://b.example", active: true)], [tab("https://c.example", space: 2)]])
        let loaded = try repo.load()
        #expect(loaded.count == 2)
        #expect(loaded[0].map(\.url) == ["https://a.example", "https://b.example"])
        #expect(loaded[0][1].isActive && !loaded[0][0].isActive)
        #expect(loaded[1][0].spaceIndex == 2 && loaded[1][0].interactionState == Data([1, 2, 3]))
    }

    @Test func savingReplacesWhatWasThere() throws {
        let (repo, cleanup) = try makeRepo(); defer { cleanup() }
        try repo.save([[tab("https://a.example")], [tab("https://b.example")]])
        try repo.save([[tab("https://c.example")]])
        #expect(try repo.load().map { $0.map(\.url) } == [["https://c.example"]])
        try repo.save([])
        #expect(try repo.load().isEmpty)
    }

    @Test func emptyWindowsDoNotLeaveGapsThatShiftTheOthers() throws {
        let (repo, cleanup) = try makeRepo(); defer { cleanup() }
        try repo.save([[], [tab("https://b.example")]])
        #expect(try repo.load().map { $0.map(\.url) } == [["https://b.example"]])
    }
}
