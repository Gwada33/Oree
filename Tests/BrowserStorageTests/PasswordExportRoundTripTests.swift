import Testing
import Foundation
import BrowserCore
@testable import BrowserStorage

struct PasswordExportRoundTripTests {
    @Test func whatIsExportedReadsBackWithTheImporter() throws {
        let rows: [PasswordCSVExporter.Row] = [.init(url: "https://a.fr", username: "ana", password: "p,w\"d"), .init(url: "https://b.fr", username: "bob", password: "simple")]
        let result = try PasswordCSVImporter.parse(PasswordCSVExporter.csv(rows))
        #expect(result.entries.map(\.password) == ["p,w\"d", "simple"] && result.entries.map(\.username) == ["ana", "bob"] && result.skipped == 0)
    }
}
