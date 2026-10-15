import Testing
import Foundation
@testable import BrowserCore

@Suite struct ZoomPolicyTests {
    @Test func stepsGoThroughTheLevels() {
        #expect(ZoomPolicy.zoomedIn(from: 1.0) == 1.1)
        #expect(ZoomPolicy.zoomedIn(from: 1.1) == 1.25)
        #expect(ZoomPolicy.zoomedOut(from: 1.0) == 0.9)
        #expect(ZoomPolicy.zoomedOut(from: 0.9) == 0.8)
        #expect(ZoomPolicy.zoomedIn(from: 1.2) == 1.25)          // from a value between two levels (pinch)
        #expect(ZoomPolicy.zoomedOut(from: 1.2) == 1.1)
    }

    @Test func stepsStopAtTheEnds() {
        #expect(ZoomPolicy.zoomedIn(from: 5.0) == 5.0)
        #expect(ZoomPolicy.zoomedOut(from: 0.3) == 0.3)
    }

    @Test func theLabelIsAPercentage() {
        #expect(ZoomPolicy.label(1.25) == "125 %")
        #expect(ZoomPolicy.label(0.67) == "67 %")
    }

    @Test func theMemoryIsKeyedBySite() {
        #expect(ZoomPolicy.key(for: URL(string: "https://www.Exemple.fr/a?b=1")) == "exemple.fr")
        #expect(ZoomPolicy.key(for: URL(string: "oree://home")) == nil)
        #expect(ZoomPolicy.key(for: URL(string: "file:///tmp/a.html")) == nil)
        #expect(ZoomPolicy.key(for: nil) == nil)
    }

    @Test func oneHundredPercentForgetsTheSite() {
        var memory = ZoomPolicy.updated([:], key: "a.fr", zoom: 1.5)
        #expect(memory == ["a.fr": 1.5])
        memory = ZoomPolicy.updated(memory, key: "a.fr", zoom: 1.0)
        #expect(memory.isEmpty)
    }

    @Test func theMemoryIsBounded() {
        var memory: [String: Double] = [:]
        for i in 0..<(ZoomPolicy.maxRemembered + 20) { memory = ZoomPolicy.updated(memory, key: "site\(i).fr", zoom: 1.5) }
        #expect(memory.count == ZoomPolicy.maxRemembered)
        #expect(memory["site\(ZoomPolicy.maxRemembered + 19).fr"] == 1.5)          // the one just set is kept
    }

    @Test func aRememberedZoomIsUsedAndKeptInRange() {
        let memory = ["a.fr": 1.5, "b.fr": 99, "c.fr": .nan]
        #expect(ZoomPolicy.zoom(for: URL(string: "https://a.fr/x"), memory: memory) == 1.5)
        #expect(ZoomPolicy.zoom(for: URL(string: "https://b.fr/x"), memory: memory) == 5.0)
        #expect(ZoomPolicy.zoom(for: URL(string: "https://c.fr/x"), memory: memory) == 1)
        #expect(ZoomPolicy.zoom(for: URL(string: "https://autre.fr"), memory: memory) == 1)
        #expect(ZoomPolicy.zoom(for: URL(string: "oree://home"), memory: memory) == 1)
    }
}
