import Testing
import Foundation
import BrowserCore
@testable import BrowserStorage

struct BoostRepositoryTests {
    private func makeRepo() throws -> (BoostRepository, () -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HyperBrowserTests-\(UUID().uuidString).sqlite")
        return (BoostRepository(database: try AppDatabase(path: url.path)), { try? FileManager.default.removeItem(at: url) })
    }

    @Test func aBoostRoundTripsWithItsRules() throws {
        let (repo, cleanup) = try makeRepo(); defer { cleanup() }
        let rules = [BoostRule(selector: "ytd-reel-shelf-renderer", declarations: ["display": "none"])]
        try repo.save(Boost(host: "www.YouTube.com", prompt: "cache les Shorts", rules: rules, calm: true))
        let boost = try #require(try repo.boost(for: "youtube.com"))
        #expect(boost.host == "youtube.com" && boost.prompt == "cache les Shorts" && boost.rules == rules && boost.calm && boost.enabled)
    }

    @Test func aSubdomainFindsItsParentSiteBoostButNotAnotherSite() throws {
        let (repo, cleanup) = try makeRepo(); defer { cleanup() }
        try repo.save(Boost(host: "example.com", rules: [BoostRule(selector: ".a", declarations: ["display": "none"])]))
        #expect(try repo.boost(for: "m.example.com") != nil)
        #expect(try repo.boost(for: "notexample.com") == nil)
        #expect(try repo.boost(for: nil) == nil)
    }

    @Test func savingAgainReplacesAndRemovingForgets() throws {
        let (repo, cleanup) = try makeRepo(); defer { cleanup() }
        try repo.save(Boost(host: "a.com", prompt: "un"))
        try repo.save(Boost(host: "a.com", prompt: "deux"))
        #expect(try repo.all().count == 1 && repo.boost(for: "a.com")?.prompt == "deux")
        try repo.remove(host: "www.a.com")
        #expect(try repo.all().isEmpty)
    }
}
