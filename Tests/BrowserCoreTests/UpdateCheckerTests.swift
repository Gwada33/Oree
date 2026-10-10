import Testing
import Foundation
@testable import BrowserCore

@Suite struct UpdateCheckerTests {
    @Test func versionComparison() {
        #expect(UpdateChecker.isNewer("1.0.1", than: "1.0.0"))
        #expect(UpdateChecker.isNewer("v1.10.0", than: "1.9.9"))
        #expect(UpdateChecker.isNewer("2.0", than: "1.9.9"))
        #expect(!UpdateChecker.isNewer("1.0", than: "1.0.0"))
        #expect(!UpdateChecker.isNewer("1.0.0", than: "1.0.1"))
    }

    @Test func parsesLatestRelease() throws {
        let json = #"{"tag_name":"v1.2.0","body":"Notes","draft":false,"prerelease":false,"assets":[{"name":"x.dmg","browser_download_url":"https://e.com/x.dmg"},{"name":"Oree-1.2.0.zip","browser_download_url":"https://e.com/Oree-1.2.0.zip"}]}"#
        let info = try #require(UpdateChecker.parse(Data(json.utf8)))
        #expect(info.version == "1.2.0")
        #expect(info.downloadURL.lastPathComponent == "Oree-1.2.0.zip")
    }

    @Test func ignoresDraftsPrereleasesAndMissingZip() {
        #expect(UpdateChecker.parse(Data(#"{"tag_name":"v2","draft":true,"assets":[]}"#.utf8)) == nil)
        #expect(UpdateChecker.parse(Data(#"{"tag_name":"v2","prerelease":true,"assets":[{"name":"a.zip","browser_download_url":"https://e.com/a.zip"}]}"#.utf8)) == nil)
        #expect(UpdateChecker.parse(Data(#"{"tag_name":"v2","assets":[]}"#.utf8)) == nil)
        #expect(UpdateChecker.parse(Data(#"{"tag_name":"v2","assets":[{"name":"a.zip","browser_download_url":"http://e.com/a.zip"}]}"#.utf8)) == nil)
    }

    @Test func findsTheChecksumNextToTheZip() throws {
        let json = #"{"tag_name":"v1.2.0","assets":[{"name":"Oree.zip","browser_download_url":"https://e.com/Oree.zip"},{"name":"Oree.zip.sha256","browser_download_url":"https://e.com/Oree.zip.sha256"}]}"#
        #expect(try #require(UpdateChecker.parse(Data(json.utf8))).checksumURL?.lastPathComponent == "Oree.zip.sha256")
        let none = #"{"tag_name":"v1.2.0","assets":[{"name":"Oree.zip","browser_download_url":"https://e.com/Oree.zip"}]}"#
        #expect(try #require(UpdateChecker.parse(Data(none.utf8))).checksumURL == nil)
    }

    @Test func readsAShasumLine() {
        let hash = String(repeating: "AB", count: 32)
        #expect(UpdateChecker.parseChecksum("\(hash)  Oree.zip\n") == hash.lowercased())
        #expect(UpdateChecker.parseChecksum("not a hash") == nil)
        #expect(UpdateChecker.parseChecksum(String(repeating: "g", count: 64)) == nil)
    }
}
