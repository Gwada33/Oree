import Testing
import Foundation
import CryptoKit
@testable import BrowserCore

private final class FakeTransport: SafeBrowsingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.withLock { _calls } }
    let responses: [String: Data]

    init(_ responses: [String: Any]) {
        self.responses = responses.mapValues { try! JSONSerialization.data(withJSONObject: $0) }
    }

    func post(endpoint: String, body: Data) async throws -> Data {
        lock.withLock { _calls.append(endpoint) }
        guard let data = responses[endpoint] else { throw URLError(.badServerResponse) }
        return data
    }
}

@Suite struct SafeBrowsingClientTests {
    static let badURL = URL(string: "http://evil.example.com/login")!
    static var badHash: Data { SafeBrowsingURL.hashedExpressions(for: badURL).first { $0.expression == "evil.example.com/login" }!.hash }

    static func updateResponse(prefix: Data, checksum: Data? = nil, wait: String = "300s") -> [String: Any] {
        let sum = checksum ?? Data(SHA256.hash(data: prefix))
        return [
            "minimumWaitDuration": wait,
            "listUpdateResponses": [[
                "threatType": "MALWARE", "responseType": "FULL_UPDATE", "newClientState": "s1",
                "additions": [["compressionType": "RAW", "rawHashes": ["prefixSize": 4, "rawHashes": prefix.base64EncodedString()]]],
                "checksum": ["sha256": sum.base64EncodedString()],
            ]],
        ]
    }

    @Test func cleanURLNeverHitsTheNetwork() async {
        let transport = FakeTransport(["threatListUpdates:fetch": Self.updateResponse(prefix: Data([1, 2, 3, 4]))])
        let client = SafeBrowsingClient(transport: transport)
        #expect(await client.updateLists())
        #expect(await client.check(URL(string: "https://example.org/")!) == nil)
        #expect(transport.calls == ["threatListUpdates:fetch"])
    }

    @Test func prefixHitIsConfirmedByFullHash() async {
        let full = Self.badHash
        let transport = FakeTransport([
            "threatListUpdates:fetch": Self.updateResponse(prefix: full.prefix(4)),
            "fullHashes:find": ["matches": [["threatType": "MALWARE", "threat": ["hash": full.base64EncodedString()], "cacheDuration": "300s"]]],
        ])
        let client = SafeBrowsingClient(transport: transport)
        await client.updateLists()
        #expect(await client.check(Self.badURL) == .malware)
        #expect(await client.check(Self.badURL) == .malware)          // cached
        #expect(transport.calls.filter { $0 == "fullHashes:find" }.count == 1)
    }

    @Test func prefixCollisionWithoutFullMatchIsSafe() async {
        let transport = FakeTransport([
            "threatListUpdates:fetch": Self.updateResponse(prefix: Self.badHash.prefix(4)),
            "fullHashes:find": ["matches": [["threatType": "MALWARE", "threat": ["hash": Data(repeating: 7, count: 32).base64EncodedString()]]]],
        ])
        let client = SafeBrowsingClient(transport: transport)
        await client.updateLists()
        #expect(await client.check(Self.badURL) == nil)
    }

    @Test func badChecksumRejectsTheUpdate() async {
        let transport = FakeTransport(["threatListUpdates:fetch": Self.updateResponse(prefix: Data([1, 2, 3, 4]), checksum: Data(repeating: 0, count: 32))])
        let client = SafeBrowsingClient(transport: transport)
        #expect(await client.updateLists() == false)
        #expect(await client.prefixCount == 0)
    }

    @Test func honoursMinimumWaitDuration() async {
        let transport = FakeTransport(["threatListUpdates:fetch": Self.updateResponse(prefix: Data([1, 2, 3, 4]))])
        let client = SafeBrowsingClient(transport: transport)
        #expect(await client.updateLists())
        #expect(await client.updateLists() == false)
        #expect(transport.calls.count == 1)
    }

    @Test func persistsAcrossLaunches() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = FakeTransport(["threatListUpdates:fetch": Self.updateResponse(prefix: Data([1, 2, 3, 4]))])
        await SafeBrowsingClient(transport: transport, directory: dir).updateLists()
        #expect(await SafeBrowsingClient(transport: transport, directory: dir).prefixCount == 1)
    }
}
