import Testing
import Foundation
import BrowserCore
@testable import BrowserStorage

struct ResumeRepositoryTests {
    private func makeRepo() throws -> (ResumeRepository, () -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HyperBrowserTests-\(UUID().uuidString).sqlite")
        return (ResumeRepository(database: try AppDatabase(path: url.path)), { try? FileManager.default.removeItem(at: url) })
    }

    @Test func videoAndReadingPartsAreKeptSeparately() throws {
        let (repo, cleanup) = try makeRepo(); defer { cleanup() }
        try repo.update(key: "k", title: "T", video: (600, 3600))
        try repo.update(key: "k", title: "T2", reading: (0.4, "Il était une fois"))
        let point = try #require(try repo.point(for: "k"))
        #expect(point.videoSeconds == 600 && point.videoDuration == 3600)
        #expect(point.readFraction == 0.4 && point.anchor == "Il était une fois" && point.title == "T2")
    }

    @Test func clearingTheLastPartRemovesTheEntry() throws {
        let (repo, cleanup) = try makeRepo(); defer { cleanup() }
        try repo.update(key: "k", title: "T", video: (600, 3600), reading: (0.4, nil))
        try repo.clearVideo(key: "k")
        let kept = try #require(try repo.point(for: "k"))
        #expect(kept.videoSeconds == nil && kept.readFraction == 0.4)
        try repo.clearReading(key: "k")
        #expect(try repo.point(for: "k") == nil)
    }

    @Test func theNewestEntriesComeFirstAndClearEmptiesEverything() throws {
        let (repo, cleanup) = try makeRepo(); defer { cleanup() }
        try repo.update(key: "a", title: "A", reading: (0.5, nil))
        Thread.sleep(forTimeInterval: 0.01)
        try repo.update(key: "b", title: "B", reading: (0.5, nil))
        #expect(try repo.recent().map(\.key) == ["b", "a"])
        try repo.clear()
        #expect(try repo.recent().isEmpty)
    }
}
