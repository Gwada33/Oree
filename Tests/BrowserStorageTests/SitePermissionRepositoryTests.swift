import Testing
import Foundation
@testable import BrowserStorage

struct SitePermissionRepositoryTests {
    private func makeRepo() throws -> (SitePermissionRepository, () -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HyperBrowserTests-\(UUID().uuidString).sqlite")
        let db = try AppDatabase(path: url.path)
        return (SitePermissionRepository(database: db), { try? FileManager.default.removeItem(at: url) })
    }

    @Test func originIgnoresPathAndKeepsNonDefaultPort() {
        #expect(SitePermissionRepository.origin(for: URL(string: "https://Example.com/a?b=1")!) == "https://example.com")
        #expect(SitePermissionRepository.origin(for: URL(string: "http://localhost:3000/x")!) == "http://localhost:3000")
        #expect(SitePermissionRepository.origin(for: URL(string: "about:blank")!) == nil)
    }

    @Test func setReadAndOverwrite() throws {
        let (repo, cleanup) = try makeRepo(); defer { cleanup() }
        #expect(try repo.decision(origin: "https://a.com", permission: .camera) == nil)
        try repo.set(origin: "https://a.com", permission: .camera, decision: .allow)
        try repo.set(origin: "https://a.com", permission: .camera, decision: .deny, scope: .permanent)
        let stored = try #require(try repo.decision(origin: "https://a.com", permission: .camera))
        #expect(stored.decision == .deny && stored.scope == .permanent)
        #expect(try repo.all().count == 1)
    }

    @Test func permissionsAreIndependentPerOriginAndKind() throws {
        let (repo, cleanup) = try makeRepo(); defer { cleanup() }
        try repo.set(origin: "https://a.com", permission: .camera, decision: .allow)
        #expect(try repo.decision(origin: "https://a.com", permission: .microphone) == nil)
        #expect(try repo.decision(origin: "https://b.com", permission: .camera) == nil)
    }

    @Test func sessionDecisionsArePurgedPermanentOnesKept() throws {
        let (repo, cleanup) = try makeRepo(); defer { cleanup() }
        try repo.set(origin: "https://a.com", permission: .camera, decision: .allow)
        try repo.set(origin: "https://b.com", permission: .camera, decision: .allow, scope: .permanent)
        try repo.purgeSessionScoped()
        #expect(try repo.all().map(\.origin) == ["https://b.com"])
    }

    @Test func resetRemovesOneOrAll() throws {
        let (repo, cleanup) = try makeRepo(); defer { cleanup() }
        try repo.set(origin: "https://a.com", permission: .camera, decision: .allow)
        try repo.set(origin: "https://a.com", permission: .location, decision: .deny)
        try repo.reset(origin: "https://a.com", permission: .camera)
        #expect(try repo.all().count == 1)
        try repo.reset(origin: "https://a.com")
        #expect(try repo.all().isEmpty)
    }
}
