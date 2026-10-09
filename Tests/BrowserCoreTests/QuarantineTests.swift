import Testing
import Foundation
@testable import BrowserCore

struct QuarantineTests {
    @Test func downloadedFileGetsTheQuarantineAttribute() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hb-quarantine-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(!Quarantine.isQuarantined(file))
        #expect(Quarantine.apply(to: file, originURL: URL(string: "https://example.com/a.txt")))
        #expect(Quarantine.isQuarantined(file))
    }

    @Test func missingFileIsReportedNotCrashed() {
        let file = URL(fileURLWithPath: "/tmp/hb-does-not-exist-\(UUID().uuidString)")
        #expect(!Quarantine.apply(to: file, originURL: nil))
    }
}
