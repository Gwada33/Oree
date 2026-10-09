import Testing
import Foundation
@testable import DownloadKit

@Suite struct AdaptiveConnectionsTests {
    /// A link where each connection adds `perConnection` until `limit` is reached.
    func throughput(_ connections: Int, perConnection: Double = 10, limit: Double = 45) -> Double { min(Double(connections) * perConnection, limit) }

    @Test func climbsWhileEachConnectionPaysOffThenSettlesAtSaturation() {
        var controller = AdaptiveConnections(minimum: 1, maximum: 16, initial: 2)
        var now = Date(timeIntervalSince1970: 1_000)
        var history: [Int] = []
        for _ in 0..<12 {
            controller.observe(throughput: throughput(controller.target) * 1_000_000, now: now)
            history.append(controller.target)
            now.addTimeInterval(2)
        }
        // Slow start: 2 → 3 (+50 %) → 5 (+50 %) → 7 (45 MB/s is the link: no gain) → back by the 2 just added → 5, hold.
        #expect(history.max() == 7)
        #expect(controller.target == 5)
        #expect(controller.isSaturated)
    }

    @Test func neverExceedsTheConfiguredMaximum() {
        var controller = AdaptiveConnections(minimum: 1, maximum: 3, initial: 2)
        var now = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<10 { controller.observe(throughput: throughput(controller.target, limit: 1_000) * 1e6, now: now); now.addTimeInterval(2); #expect(controller.target <= 3) }
        #expect(controller.target == 3)
    }

    @Test func holdsAfterSaturationThenProbesAgain() {
        var controller = AdaptiveConnections(minimum: 1, maximum: 16, initial: 4, saturatedHold: 20)
        var now = Date(timeIntervalSince1970: 1_000)
        controller.observe(throughput: 40e6, now: now); now.addTimeInterval(2)   // 4 → 5 (probe)
        controller.observe(throughput: 40e6, now: now); now.addTimeInterval(2)   // no gain → back to 4, hold
        #expect(controller.target == 4 && controller.isSaturated)
        controller.observe(throughput: 40e6, now: now.addingTimeInterval(5))     // still holding
        #expect(controller.target == 4)
        controller.observe(throughput: 40e6, now: now.addingTimeInterval(25))    // hold over → probe again
        #expect(controller.target == 5)
    }

    @Test func serverPushBackLowersAndFreezes() {
        var controller = AdaptiveConnections(minimum: 1, maximum: 16, initial: 6, pushBackHold: 45)
        let now = Date(timeIntervalSince1970: 1_000)
        controller.serverPushedBack(now: now)
        #expect(controller.target == 5)
        controller.observe(throughput: 100e6, now: now.addingTimeInterval(10))
        #expect(controller.target == 5, "no growth during the hold")
        controller.serverPushedBack(now: now); controller.serverPushedBack(now: now); controller.serverPushedBack(now: now)
        controller.serverPushedBack(now: now); controller.serverPushedBack(now: now); controller.serverPushedBack(now: now)
        #expect(controller.target == 1, "never below the minimum")
    }

    @Test func doesNotGrowNearTheEnd() {
        var controller = AdaptiveConnections(minimum: 1, maximum: 16, initial: 3)
        controller.observe(throughput: 30e6, now: Date(), canGrow: false)
        #expect(controller.target == 3)
    }

    @Test func throughputWindow() {
        var window = ThroughputWindow()
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(window.sample(bytes: 0, now: t0) == nil)
        #expect(window.sample(bytes: 10_000_000, now: t0.addingTimeInterval(2)) == 5_000_000)
    }
}

@Suite struct LinkAndMetalinkTests {
    @Test func linkHeadersAreParsed() {
        let base = URL(string: "https://origin.example/files/a.iso")!
        let header = "<https://mirror1.example/a.iso>; rel=duplicate; pri=1, </other/a.iso>; rel=duplicate; pri=2, <a.meta4>; rel=describedby; type=\"application/metalink4+xml\""
        let links = HTTPParsing.links(header, base: base)
        #expect(links.count == 3)
        #expect(links[0] == HTTPLink(url: URL(string: "https://mirror1.example/a.iso")!, rel: "duplicate", type: nil, priority: 1))
        #expect(links[1].url.absoluteString == "https://origin.example/other/a.iso")
        #expect(links[2].rel == "describedby" && links[2].type == "application/metalink4+xml")
        #expect(links[2].url.absoluteString == "https://origin.example/files/a.meta4")
    }

    @Test func linkParsingToleratesGarbage() {
        #expect(HTTPParsing.links(nil, base: URL(string: "https://x.example")!).isEmpty)
        #expect(HTTPParsing.links("not a link", base: URL(string: "https://x.example")!).isEmpty)
    }

    @Test func metalink4IsParsedAndSortedByPriority() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <metalink xmlns="urn:ietf:params:xml:ns:metalink">
          <file name="a.iso"><size>12345</size>
            <hash type="sha-256">ABCDEF</hash>
            <url priority="2">https://m2.example/a.iso</url>
            <url priority="1">https://m1.example/a.iso</url>
            <url>ftp://ignored.example/a.iso</url>
          </file>
        </metalink>
        """
        let parsed = try #require(Metalink.parse(Data(xml.utf8)))
        #expect(parsed.size == 12345)
        #expect(parsed.sha256 == "abcdef")
        #expect(parsed.urls.map(\.url.absoluteString) == ["https://m1.example/a.iso", "https://m2.example/a.iso"])
        #expect(Metalink.parse(Data("<nope/>".utf8)) == nil)
    }
}
