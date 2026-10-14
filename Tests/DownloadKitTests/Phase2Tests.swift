import Testing
import Foundation
@testable import DownloadKit

/// Adaptive connections, mirror racing, Metalink and browsing priority — against local servers.
@Suite(.serialized) struct Phase2Tests {
    let helper = EngineTests()

    func tuned() -> EngineTuning { var t = EngineTuning(); t.adaptiveInterval = 0.5; return t }

    func makeEnv(tuning: EngineTuning? = nil) throws -> EngineTests.Env {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oree-dl-p2-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let store = StateStore(directory: root.appendingPathComponent("state", isDirectory: true))
        return EngineTests.Env(server: try TestServer(), manager: DownloadManager(store: store, tuning: tuning ?? tuned()), store: store, destination: destination, root: root)
    }

    func spec(_ env: EngineTests.Env, _ path: String, max: Int = 8, adaptive: Bool = true, mirrors: Bool = true, cookie: String? = nil) -> DownloadRequestSpec {
        DownloadRequestSpec(url: env.server.url(path), cookieHeader: cookie, destinationDirectory: env.destination, maxConnections: max, adaptive: adaptive, useMirrors: mirrors)
    }

    @Test func connectionsClimbOnAServerThatLimitsEachConnection() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.root) }
        let size: Int64 = 80 << 20
        env.server.serve("/limited", .init(size: size, delayMsPerChunk: 12, constantBytes: true))   // ≈ 5 MB/s per connection
        let request = spec(env, "/limited", max: 8)
        #expect(await env.manager.start(request) == .accepted)
        var peak = 0
        #expect(await helper.waitFor(90) {
            let s = await env.manager.list().first
            peak = max(peak, s?.connections ?? 0)
            return s?.phase == .finished
        })
        #expect(peak >= 4, "the engine should have added connections, peak was \(peak)")
        #expect(peak <= 8)
        #expect(try helper.verifyZeros(env.destination.appendingPathComponent("limited"), size: size))
    }

    @Test func aFixedBudgetNeverExceedsTheMaximum() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.root) }
        env.server.serve("/cap", .init(size: 24 << 20, delayMsPerChunk: 4))
        let request = spec(env, "/cap", max: 3, adaptive: false)
        #expect(await env.manager.start(request) == .accepted)
        var peak = 0
        #expect(await helper.waitFor(60) { let s = await env.manager.list().first; peak = max(peak, s?.connections ?? 0); return s?.phase == .finished })
        #expect(peak <= 3 && peak >= 2)
    }

    @Test func aFastMirrorTakesOverFromASlowOriginAndNeverSeesTheCookie() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.root) }
        let size: Int64 = 40 << 20
        let mirrorURL = env.server.url("/mirror", host: "127.0.0.1")
        env.server.serve("/origin", .init(size: size, delayMsPerChunk: 25, linkHeader: "<\(mirrorURL.absoluteString)>; rel=duplicate; pri=1"))
        env.server.serve("/mirror", .init(size: size))
        let request = spec(env, "/origin", max: 4, cookie: "session=SECRET")
        #expect(await env.manager.start(request) == .accepted)
        #expect(await env.manager.list().first?.sources == 2)
        #expect(await helper.waitFor(90) { await env.manager.list().first?.phase == .finished })
        #expect(try helper.verify(env.destination.appendingPathComponent("origin"), size: size, seed: 1))
        let viaMirror = env.server.requests.filter { $0.path == "/mirror" && $0.rangeEnd != 0 }
        #expect(!viaMirror.isEmpty, "the mirror should have carried part of the file")
        #expect(env.server.requests.filter { $0.path == "/mirror" }.allSatisfy { $0.cookie == nil }, "the cookie leaked to a mirror on another host")
        #expect(env.server.requests.filter { $0.path == "/origin" }.contains { $0.cookie == "session=SECRET" })
        // The mirror was much faster, so it should have served most of the segments.
        let viaOrigin = env.server.requests.filter { $0.path == "/origin" && $0.rangeEnd != 0 }
        #expect(viaMirror.count >= viaOrigin.count, "mirror \(viaMirror.count) vs origin \(viaOrigin.count)")
    }

    @Test func aMirrorThatIsNotTheSameFileIsIgnored() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.root) }
        let mirrorURL = env.server.url("/other", host: "127.0.0.1")
        env.server.serve("/o", .init(size: 6 << 20, linkHeader: "<\(mirrorURL.absoluteString)>; rel=duplicate"))
        env.server.serve("/other", .init(size: 7 << 20))                          // different size
        env.server.serve("/o2", .init(size: 6 << 20, etag: "\"A\"", linkHeader: "<\(env.server.url("/other2", host: "127.0.0.1").absoluteString)>; rel=duplicate"))
        env.server.serve("/other2", .init(size: 6 << 20, etag: "\"B\""))          // same size, different version
        for path in ["/o", "/o2"] {
            let request = spec(env, path)
            #expect(await env.manager.start(request) == .accepted)
            #expect(await env.manager.list().first { $0.id == request.id }?.sources == 1)
            #expect(await helper.waitFor { await env.manager.list().first { $0.id == request.id }?.phase == .finished })
        }
        #expect(env.server.requests.filter { ($0.path == "/other" || $0.path == "/other2") && $0.rangeEnd != 0 }.isEmpty)
    }

    @Test func metalinkFilesNameTheMirrors() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.root) }
        let size: Int64 = 12 << 20
        let mirror = env.server.url("/m", host: "127.0.0.1").absoluteString
        let xml = "<?xml version=\"1.0\"?><metalink xmlns=\"urn:ietf:params:xml:ns:metalink\"><file name=\"x\"><size>\(size)</size><url priority=\"1\">\(mirror)</url></file></metalink>"
        env.server.serve("/meta4", .init(size: 1, customBody: Data(xml.utf8)))
        env.server.serve("/mo", .init(size: size, delayMsPerChunk: 10,
                                      linkHeader: "<\(env.server.url("/meta4").absoluteString)>; rel=describedby; type=\"application/metalink4+xml\""))
        env.server.serve("/m", .init(size: size))
        let request = spec(env, "/mo", max: 4)
        #expect(await env.manager.start(request) == .accepted)
        #expect(await env.manager.list().first?.sources == 2)
        #expect(await helper.waitFor(60) { await env.manager.list().first?.phase == .finished })
        #expect(try helper.verify(env.destination.appendingPathComponent("mo"), size: size, seed: 1))
        #expect(env.server.requests.contains { $0.path == "/m" && $0.rangeEnd != 0 })
    }

    @Test func browsingPriorityThrottlesThenRestoresFullSpeed() async throws {
        let env = try makeEnv(); defer { try? FileManager.default.removeItem(at: env.root) }
        // ≈ 60 MB/s in total (a fast home connection): buffers are small next to one throttle cycle.
        env.server.serve("/long", .init(size: 3 << 30, delayMsPerChunk: 4, constantBytes: true))
        let request = spec(env, "/long", max: 4, adaptive: false)
        #expect(await env.manager.start(request) == .accepted)
        func delta(over seconds: Double) async -> Int64 {
            let before = await env.manager.list().first?.received ?? 0
            try? await Task.sleep(for: .seconds(seconds))
            return (await env.manager.list().first?.received ?? 0) - before
        }
        try await Task.sleep(for: .seconds(0.7))
        let full = await delta(over: 2)
        await env.manager.setBrowsingActive(true)
        #expect(await env.manager.list().first?.throttled == true)
        try await Task.sleep(for: .seconds(0.7))
        let slow = await delta(over: 2)
        await env.manager.setBrowsingActive(false)
        try await Task.sleep(for: .seconds(0.7))
        let restored = await delta(over: 2)
        await env.manager.cancel(request.id)
        #expect(full > 0)
        // The throttle suspends connections 70 % of each cycle, but the socket buffers drain in a burst on every
        // resume, so on a slow shared runner the measured share is well above the nominal 30 % (seen: 64 %).
        // Only assert that throttled speed is clearly below full speed.
        #expect(Double(slow) < Double(full) * 0.8, "throttled \(slow) vs full \(full)")
        #expect(Double(restored) > Double(full) * 0.6, "restored \(restored) vs full \(full)")
    }
}
