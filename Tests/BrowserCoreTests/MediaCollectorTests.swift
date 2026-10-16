import Testing
import Foundation
@testable import BrowserCore

@Suite struct MediaCollectorTests {
    @Test func keepsOrderDropsDuplicatesAndUnreachableSchemes() {
        let json = #"[{"url":"/a.jpg","kind":"image"},{"url":"https://x.test/a.jpg","kind":"image"},{"url":"data:image/png;base64,AA","kind":"image"},{"url":"blob:https://x.test/1","kind":"video"},{"url":"v.mp4","kind":"video"},{"url":"z","kind":"bogus"}]"#
        let media = MediaCollector.parse(json: json, base: URL(string: "https://x.test/page/"))
        #expect(media.map(\.url.absoluteString) == ["https://x.test/a.jpg", "https://x.test/page/v.mp4"])
        #expect(media.map(\.kind) == [.image, .video])
    }

    @Test func fileNamesNeverCollide() {
        let m = ["https://x.test/a/photo.jpg", "https://y.test/b/photo.jpg", "https://x.test/", "https://x.test/..%2Fevil"]
            .map { PageMedia(url: URL(string: $0)!, kind: .image) }
        let names = MediaCollector.fileNames(for: m)
        #expect(names[0] == "photo.jpg" && names[1] == "photo 2.jpg")
        #expect(Set(names.map { $0.lowercased() }).count == 4)
        #expect(names.allSatisfy { !$0.contains("/") })
    }

    @Test func garbageGivesNothing() {
        #expect(MediaCollector.parse(json: "pas du json", base: nil).isEmpty)
    }
}
