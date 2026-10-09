import Testing
import Foundation
@testable import BrowserCore

struct SiteMemoryPolicyTests {
    private func profile(_ mb: Double, samples: Int = 5) -> SiteProfile { .init(host: "a.com", samples: samples, averageMB: mb, peakMB: mb * 1.2) }

    @Test func averageStartsAsAPlainMeanThenFollowsRecentVisits() {
        #expect(SiteMemoryPolicy.updatedAverage(old: 0, samples: 0, new: 300) == 300)
        #expect(SiteMemoryPolicy.updatedAverage(old: 300, samples: 1, new: 500) == 400)          // mean of two
        let later = SiteMemoryPolicy.updatedAverage(old: 300, samples: 50, new: 800)
        #expect(later == 400)                                                                       // 0.2 weight: adapts, doesn't jump
    }

    @Test func heavyNeedsEnoughSamplesAndEnoughMemory() {
        #expect(SiteMemoryPolicy.isHeavy(profile(600)))
        #expect(!SiteMemoryPolicy.isHeavy(profile(200)))
        #expect(!SiteMemoryPolicy.isHeavy(profile(900, samples: 2)))
        #expect(!SiteMemoryPolicy.isHeavy(nil))
    }

    @Test func predictionIsZeroUntilTheProfileIsReliable() {
        #expect(SiteMemoryPolicy.predictedBytes(for: nil) == 0)
        #expect(SiteMemoryPolicy.predictedBytes(for: profile(500, samples: 1)) == 0)
        #expect(SiteMemoryPolicy.predictedBytes(for: profile(500)) == 500 * 1_048_576)
    }

    @Test func heavySitesSleepSooner() {
        #expect(SiteMemoryPolicy.idleLimit(base: 600, profile: profile(600)) == 180)
        #expect(SiteMemoryPolicy.idleLimit(base: 600, profile: profile(100)) == 600)
        #expect(SiteMemoryPolicy.idleLimit(base: 60, profile: profile(600)) == 60)   // never longer than the base
    }

    @Test func hostsAreNormalised() {
        #expect(SiteMemoryPolicy.normalizedHost(URL(string: "https://WWW.Example.com/a?b=1")) == "example.com")
        #expect(SiteMemoryPolicy.normalizedHost(URL(string: "http://sub.example.com")) == "sub.example.com")
        #expect(SiteMemoryPolicy.normalizedHost(URL(string: "about:blank")) == nil)
        #expect(SiteMemoryPolicy.normalizedHost(URL(string: "file:///tmp/a.html")) == nil)
        #expect(SiteMemoryPolicy.normalizedHost(nil) == nil)
    }
}
