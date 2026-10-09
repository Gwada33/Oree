import Testing
import Foundation
@testable import BrowserStorage

struct SiteMemoryRepositoryTests {
    private func makeRepo() throws -> (SiteMemoryRepository, () -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HyperBrowserTests-\(UUID().uuidString).sqlite")
        return (SiteMemoryRepository(database: try AppDatabase(path: url.path)), { try? FileManager.default.removeItem(at: url) })
    }

    @Test func recordsAverageAndPeak() throws {
        let (repo, cleanup) = try makeRepo(); defer { cleanup() }
        try repo.record(host: "a.com", megabytes: 300)
        try repo.record(host: "a.com", megabytes: 500)
        let profile = try #require(try repo.profile(host: "a.com"))
        #expect(profile.samples == 2 && profile.averageMB == 400 && profile.peakMB == 500)
        #expect(try repo.profile(host: "other.com") == nil)
    }

    @Test func ignoresNonsenseMeasurements() throws {
        let (repo, cleanup) = try makeRepo(); defer { cleanup() }
        try repo.record(host: "a.com", megabytes: 0)
        try repo.record(host: "a.com", megabytes: -5)
        try repo.record(host: "a.com", megabytes: .nan)
        #expect(try repo.profile(host: "a.com") == nil)
    }

    @Test func heaviestListsOnlyReliableSitesInOrder() throws {
        let (repo, cleanup) = try makeRepo(); defer { cleanup() }
        for _ in 0..<3 { try repo.record(host: "heavy.com", megabytes: 800) }
        for _ in 0..<3 { try repo.record(host: "medium.com", megabytes: 400) }
        try repo.record(host: "once.com", megabytes: 2000)          // one sample only: not reliable yet
        #expect(try repo.heaviest().map(\.host) == ["heavy.com", "medium.com"])
    }

    @Test func clearForgetsEverything() throws {
        let (repo, cleanup) = try makeRepo(); defer { cleanup() }
        try repo.record(host: "a.com", megabytes: 300)
        try repo.clear()
        #expect(try repo.profile(host: "a.com") == nil)
    }
}
