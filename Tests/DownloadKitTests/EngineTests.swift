import Testing
import Foundation
@testable import DownloadKit

/// End-to-end tests of the engine against a local server that supports Range.
@Suite(.serialized) struct EngineTests {
    struct Env {
        let server: TestServer
        let manager: DownloadManager
        let store: StateStore
        let destination: URL
        let root: URL
    }

    func makeEnv(allowed: [URL]? = nil) throws -> Env {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oree-dl-tests-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let store = StateStore(directory: root.appendingPathComponent("state", isDirectory: true))
        return Env(server: try TestServer(), manager: DownloadManager(store: store, allowedDirectories: allowed), store: store, destination: destination, root: root)
    }

    func waitFor(_ timeout: Double = 30, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func phase(_ env: Env, _ id: UUID) async -> DownloadSnapshot? { await env.manager.list().first { $0.id == id } }

    func verify(_ url: URL, size: Int64, seed: UInt8) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset: Int64 = 0
        while offset < size {
            let want = Int(min(1 << 20, size - offset))
            guard let data = try handle.read(upToCount: want), data.count == want else { return false }
            if data != TestServer.bytes(from: offset, count: want, seed: seed) { return false }
            offset += Int64(want)
        }
        return (try handle.read(upToCount: 1) ?? Data()).isEmpty
    }

    func verifyZeros(_ url: URL, size: Int64) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset: Int64 = 0
        while offset < size {
            let want = Int(min(1 << 20, size - offset))
            guard let data = try handle.read(upToCount: want), data.count == want, !data.contains(where: { $0 != 0 }) else { return false }
            offset += Int64(want)
        }
        return true
    }

    func spec(_ env: Env, _ path: String, connections: Int = 4, host: String = "localhost", cookie: String? = nil) -> DownloadRequestSpec {
        DownloadRequestSpec(url: env.server.url(path, host: host), cookieHeader: cookie, pageURL: URL(string: "https://example.com/page"),
                            destinationDirectory: env.destination, maxConnections: connections)
    }

    @Test func segmentedDownloadWritesExactBytesOverSeveralConnections() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.root) }
        let size: Int64 = 12 << 20
        env.server.serve("/big", .init(size: size, delayMsPerChunk: 2, contentDisposition: "attachment; filename=\"gros.bin\""))
        let request = spec(env, "/big")
        #expect(await env.manager.start(request) == .accepted)
        #expect(await waitFor { await phase(env, request.id)?.phase == .finished })

        let final = env.destination.appendingPathComponent("gros.bin")
        #expect(try verify(final, size: size, seed: 1))
        #expect(env.server.maxActive >= 2, "expected parallel connections, saw \(env.server.maxActive)")
        #expect(Quarantine.isTagged(final), "finished file must carry the quarantine attribute")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: env.destination.path).filter { $0.hasSuffix(".oreedl") }
        #expect(leftovers.isEmpty)
    }

    @Test func freedConnectionsAreReusedBySplittingTheBiggestSegment() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.root) }
        let size: Int64 = 16 << 20
        // The first half is slow, the second fast: the fast connection finishes early and must help the slow one.
        env.server.serve("/skew", .init(size: size, delayMsPerChunk: 4, slowBelow: 8 << 20))
        let request = spec(env, "/skew", connections: 2)
        #expect(await env.manager.start(request) == .accepted)
        #expect(await waitFor(60) { await phase(env, request.id)?.phase == .finished })
        let rangeStarts = env.server.requests.compactMap(\.rangeStart).filter { $0 > 0 }
        #expect(rangeStarts.count >= 2, "expected extra Range requests from re-splitting, got \(rangeStarts)")
        #expect(try verify(env.destination.appendingPathComponent("skew"), size: size, seed: 1))
    }

    @Test func serversWithoutRangeAreHandedBack() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.root) }
        env.server.serve("/plain", .init(size: 4 << 20, supportsRange: false))
        let outcome = await env.manager.start(spec(env, "/plain"))
        guard case .unsupported = outcome else { Issue.record("expected unsupported, got \(outcome)"); return }
        #expect(await env.manager.list().isEmpty)
    }

    @Test func pauseThenResumeContinuesWhereItStopped() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.root) }
        let size: Int64 = 16 << 20
        env.server.serve("/slow", .init(size: size, delayMsPerChunk: 8))
        let request = spec(env, "/slow", connections: 2)
        #expect(await env.manager.start(request) == .accepted)
        #expect(await waitFor { (await phase(env, request.id)?.received ?? 0) > 2 << 20 })
        await env.manager.pause(request.id)
        let paused = try #require(await phase(env, request.id))
        #expect(paused.phase == .paused)
        #expect(paused.received > 0 && paused.received < size)
        let saved = try #require(env.store.load(request.id))
        #expect(saved.phase == .paused)
        #expect(SegmentPlanner.tiles(saved.segments, total: size))

        let requestsBefore = env.server.requests.count
        env.server.update("/slow") { $0.delayMsPerChunk = 0 }
        await env.manager.resume(request.id)
        #expect(await waitFor { await phase(env, request.id)?.phase == .finished })
        #expect(try verify(env.destination.appendingPathComponent("slow"), size: size, seed: 1))
        // After resuming, no request restarts from byte 0 (the first bytes were kept).
        let after = env.server.requests.dropFirst(requestsBefore).filter { $0.rangeEnd != 0 }.compactMap(\.rangeStart)   // (the 1-byte validation probe is excluded)
        #expect(!after.contains(0), "resume must not re-download from the start, got \(after)")
    }

    @Test func aFileChangedOnTheServerRestartsCleanly() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.root) }
        let size: Int64 = 12 << 20
        env.server.serve("/changing", .init(size: size, seed: 1, etag: "\"v1\"", delayMsPerChunk: 8))
        let request = spec(env, "/changing", connections: 2)
        #expect(await env.manager.start(request) == .accepted)
        #expect(await waitFor { (await phase(env, request.id)?.received ?? 0) > 1 << 20 })
        await env.manager.pause(request.id)

        env.server.update("/changing") { $0.seed = 9; $0.etag = "\"v2\""; $0.delayMsPerChunk = 0 }
        await env.manager.resume(request.id)
        #expect(await waitFor { await phase(env, request.id)?.phase == .finished })
        #expect(try verify(env.destination.appendingPathComponent("changing"), size: size, seed: 9), "the new version must be fully downloaded")
    }

    @Test func throttlingIsRespectedAndTheDownloadStillCompletes() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.root) }
        let size: Int64 = 6 << 20
        env.server.serve("/busy", .init(size: size, fail429First: 2))
        let request = spec(env, "/busy", connections: 3)
        let started = Date()
        #expect(await env.manager.start(request) == .accepted)
        #expect(await waitFor(60) { await phase(env, request.id)?.phase == .finished })
        #expect(Date().timeIntervalSince(started) >= 1, "Retry-After: 1 must be honored")
        #expect(env.server.requests.filter { $0.status == 429 }.count == 2)
        #expect(try verify(env.destination.appendingPathComponent("busy"), size: size, seed: 1))
    }

    @Test func aRelaunchedManagerFindsPausedDownloadsAndResumesThem() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.root) }
        let size: Int64 = 12 << 20
        env.server.serve("/relaunch", .init(size: size, delayMsPerChunk: 8))
        let request = spec(env, "/relaunch", connections: 2)
        #expect(await env.manager.start(request) == .accepted)
        #expect(await waitFor { (await phase(env, request.id)?.received ?? 0) > 2 << 20 })
        await env.manager.pause(request.id)

        let reborn = DownloadManager(store: env.store)       // a new process, same state folder
        await reborn.loadPersisted()
        let listed = try #require(await reborn.list().first)
        #expect(listed.phase == .paused && listed.received > 0)
        env.server.update("/relaunch") { $0.delayMsPerChunk = 0 }
        await reborn.resume(request.id)
        #expect(await waitFor { await reborn.list().first?.phase == .finished })
        #expect(try verify(env.destination.appendingPathComponent("relaunch"), size: size, seed: 1))
    }

    @Test func destinationsOutsideTheAllowedFoldersAreRefused() async throws {
        let env = try makeEnv(allowed: [FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere")])
        defer { try? FileManager.default.removeItem(at: env.root) }
        env.server.serve("/x", .init(size: 2 << 20))
        guard case .unsupported = await env.manager.start(spec(env, "/x")) else { Issue.record("must refuse"); return }
    }

    @Test func cookiesAreNeverForwardedToAnotherHost() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.root) }
        let size: Int64 = 3 << 20
        env.server.serve("/start", .init(size: size, redirectTo: env.server.url("/real", host: "127.0.0.1").absoluteString))
        env.server.serve("/real", .init(size: size))
        // "/start" redirects every request (probe included) to the other host.
        let request = spec(env, "/start", connections: 2, cookie: "session=SECRET")
        #expect(await env.manager.start(request) == .accepted)
        #expect(await waitFor { await phase(env, request.id)?.phase == .finished })
        let toOtherHost = env.server.requests.filter { $0.path == "/real" }
        #expect(!toOtherHost.isEmpty)
        #expect(toOtherHost.allSatisfy { $0.cookie == nil }, "the cookie leaked to another host")
        #expect(env.server.requests.filter { $0.path == "/start" }.allSatisfy { $0.cookie == "session=SECRET" })
    }
}

enum Quarantine {
    static func isTagged(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties != nil
    }
}
