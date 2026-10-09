import Testing
import Foundation
@testable import DownloadKit

@Suite struct SegmentPlannerTests {
    @Test func initialSegmentsTileTheFileExactly() {
        for total in [1, 5, 1_000_000, 1 << 20, (1 << 20) * 3 + 17, 10_000_000_000] as [Int64] {
            for connections in [1, 2, 4, 7, 16] {
                let segments = SegmentPlanner.initial(total: total, connections: connections)
                #expect(SegmentPlanner.tiles(segments, total: total), "total \(total) × \(connections)")
                #expect(segments.count <= connections)
            }
        }
    }

    @Test func smallFilesUseFewerSegments() {
        #expect(SegmentPlanner.initial(total: 500_000, connections: 8).count == 1)
        #expect(SegmentPlanner.initial(total: 3 << 20, connections: 8).count == 3)
    }

    @Test func emptyFileHasNoSegments() {
        #expect(SegmentPlanner.initial(total: 0, connections: 4).isEmpty)
    }

    @Test func splitTakesTheSecondHalfOfTheBiggestRemainder() {
        var segments = [Segment(start: 0, end: 10 << 20, next: 9 << 20), Segment(start: 10 << 20, end: 30 << 20, next: 10 << 20)]
        let index = SegmentPlanner.splitLargest(&segments)
        #expect(index == 2)
        #expect(segments[1].end == 20 << 20)            // 20 MiB remaining → first half stays
        #expect(segments[2] == Segment(start: 20 << 20, end: 30 << 20))
        #expect(SegmentPlanner.tiles(segments, total: 30 << 20))
    }

    @Test func splitRefusesTinyRemainders() {
        var segments = [Segment(start: 0, end: 3 << 20, next: 2 << 20 + 500_000)]
        #expect(SegmentPlanner.splitLargest(&segments) == nil)
        #expect(segments.count == 1)
    }

    @Test func repeatedSplitsKeepTilingAndNeverLoseBytes() {
        var segments = SegmentPlanner.initial(total: 100 << 20, connections: 2)
        segments[0].next = 10 << 20
        while SegmentPlanner.splitLargest(&segments) != nil {}
        #expect(SegmentPlanner.tiles(segments, total: 100 << 20))
        #expect(SegmentPlanner.received(segments) == 10 << 20)
        #expect(segments.count > 4)
    }
}

@Suite struct HTTPParsingTests {
    @Test func contentRangeTotal() {
        #expect(HTTPParsing.totalFromContentRange("bytes 0-0/12345") == 12345)
        #expect(HTTPParsing.totalFromContentRange("bytes 0-0/*") == nil)
        #expect(HTTPParsing.totalFromContentRange(nil) == nil)
    }

    @Test func retryAfter() {
        #expect(HTTPParsing.retryAfterSeconds("120") == 120)
        #expect(HTTPParsing.retryAfterSeconds("-5") == 0)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = "Wed, 15 Jan 2027 08:01:00 GMT"   // 60 s after `now` (08:00:00)
        let nowAt = DateFormatter.http.date(from: "Wed, 15 Jan 2027 08:00:00 GMT")!
        #expect(HTTPParsing.retryAfterSeconds(future, now: nowAt) == 60)
        _ = now
        #expect(HTTPParsing.retryAfterSeconds("garbage") == nil)
    }

    @Test func fileNames() {
        let url = URL(string: "https://cdn.example.com/a/b/archive%20v2.zip?token=abc")!
        #expect(HTTPParsing.fileName(contentDisposition: nil, url: url) == "archive v2.zip")
        #expect(HTTPParsing.fileName(contentDisposition: "attachment; filename=\"rapport.pdf\"", url: url) == "rapport.pdf")
        #expect(HTTPParsing.fileName(contentDisposition: "attachment; filename=\"a.pdf\"; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf", url: url) == "résumé.pdf")
        #expect(HTTPParsing.fileName(contentDisposition: nil, url: URL(string: "https://x.example/")!, suggested: "x.bin") == "x.bin")
    }

    @Test func namesCannotEscapeTheFolder() {
        #expect(HTTPParsing.sanitize("../../etc/passwd") == "passwd")
        #expect(HTTPParsing.sanitize("..hidden") == "hidden")
        #expect(HTTPParsing.sanitize("  ") == "téléchargement")
        #expect(HTTPParsing.sanitize("a:b/c") == "c")
    }

    @Test func weakETagsAreIgnored() {
        #expect(HTTPParsing.strongETag("\"abc\"") == "\"abc\"")
        #expect(HTTPParsing.strongETag("W/\"abc\"") == nil)
        #expect(HTTPParsing.strongETag("") == nil)
    }

    @Test func backoffGrowsAndHonorsRetryAfter() {
        #expect(Backoff.delay(attempt: 0, jitter: 1) == 1)
        #expect(Backoff.delay(attempt: 3, jitter: 1) == 8)
        #expect(Backoff.delay(attempt: 20, jitter: 1) == 60)
        #expect(Backoff.delay(attempt: 0, retryAfter: 30, jitter: 1) == 30)
        #expect(Backoff.delay(attempt: 0, retryAfter: 100_000) == 600)
    }
}

extension DateFormatter {
    static let http: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()
}
