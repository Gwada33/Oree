import Testing
import Foundation
@testable import BrowserCore

@Suite struct ResumePolicyTests {
    private func key(_ s: String) -> String? { ResumePolicy.key(for: URL(string: s)) }

    @Test func keyIgnoresFragmentsTrackingAndTimeButKeepsTheVideoId() {
        #expect(key("https://www.youtube.com/watch?v=abc&t=120s&utm_source=x#top") == "https://youtube.com/watch?v=abc")
        #expect(key("https://youtube.com/watch?t=5&v=abc") == "https://youtube.com/watch?v=abc")        // parameter order does not matter
        #expect(key("https://example.com/article#section-2") == "https://example.com/article")
        #expect(key("https://example.com/a?page=2") != key("https://example.com/a?page=3"))
    }

    @Test func onlyWebPagesHaveAKey() {
        #expect(key("oree://home") == nil)
        #expect(key("file:///tmp/a.html") == nil)
        #expect(ResumePolicy.key(for: nil) == nil)
    }

    @Test func videoPositionIsKeptOnlyInTheMiddleOfALongVideo() {
        #expect(ResumePolicy.isWorthKeeping(videoSeconds: 600, duration: 3600))
        #expect(!ResumePolicy.isWorthKeeping(videoSeconds: 10, duration: 3600))              // hardly started
        #expect(!ResumePolicy.isWorthKeeping(videoSeconds: 3590, duration: 3600))            // finished
        #expect(!ResumePolicy.isWorthKeeping(videoSeconds: 100, duration: 120))              // a short clip
        #expect(!ResumePolicy.isWorthKeeping(videoSeconds: .nan, duration: 3600))
        #expect(!ResumePolicy.isWorthKeeping(videoSeconds: 100, duration: .infinity))        // a live stream
    }

    @Test func readingIsKeptOnlyOnLongPagesInTheMiddle() {
        #expect(ResumePolicy.isWorthKeeping(readFraction: 0.5, screens: 8))
        #expect(!ResumePolicy.isWorthKeeping(readFraction: 0.5, screens: 2))
        #expect(!ResumePolicy.isWorthKeeping(readFraction: 0.01, screens: 8))
        #expect(!ResumePolicy.isWorthKeeping(readFraction: 0.99, screens: 8))
    }

    @Test func clockFormatsMinutesAndHours() {
        #expect(ResumePolicy.clock(754) == "12:34")
        #expect(ResumePolicy.clock(3723) == "1:02:03")
        #expect(ResumePolicy.clock(-5) == "0:00")
    }

    @Test func offerPrefersTheVideoThenReadingAndForgetsOldPoints() {
        let fresh = ResumePoint(key: "k", title: "t", videoSeconds: 300, videoDuration: 1800, readFraction: 0.4)
        #expect(ResumePolicy.offer(for: fresh) == .video(seconds: 300))
        let reading = ResumePoint(key: "k", title: "t", readFraction: 0.62)
        #expect(ResumePolicy.offer(for: reading) == .reading(percent: 62))
        let finished = ResumePoint(key: "k", title: "t", videoSeconds: 1790, videoDuration: 1800)
        #expect(ResumePolicy.offer(for: finished) == nil)
        let old = ResumePoint(key: "k", title: "t", readFraction: 0.5, updatedAt: Date(timeIntervalSinceNow: -91 * 86_400))
        #expect(ResumePolicy.offer(for: old) == nil)
        #expect(ResumePolicy.offer(for: nil) == nil)
    }
}
