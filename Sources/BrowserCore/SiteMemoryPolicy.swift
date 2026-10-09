import Foundation

/// What the browser has learned about one site's memory use (kept locally, host and numbers only).
public struct SiteProfile: Equatable, Sendable {
    public let host: String
    public let samples: Int
    public let averageMB: Double
    public let peakMB: Double

    public init(host: String, samples: Int, averageMB: Double, peakMB: Double) {
        self.host = host; self.samples = samples; self.averageMB = averageMB; self.peakMB = peakMB
    }
}

/// How learned site memory changes decisions. Pure functions, so they're easy to test.
public enum SiteMemoryPolicy {
    /// A site averaging more than this is treated as "heavy".
    public static let heavyThresholdMB = 350.0
    /// Don't trust a profile built from fewer visits/samples than this.
    public static let minimumSamples = 3
    /// A heavy site that's out of sight sleeps after at most this long.
    public static let heavyIdleLimit: TimeInterval = 180

    /// Running average that adapts: plain mean at first, then weighted towards recent samples
    /// so a site that got lighter (or heavier) is followed within a few visits.
    public static func updatedAverage(old: Double, samples: Int, new: Double) -> Double {
        guard samples > 0 else { return new }
        let weight = max(1.0 / Double(samples + 1), 0.2)
        return old + (new - old) * weight
    }

    public static func isHeavy(_ profile: SiteProfile?) -> Bool {
        guard let profile, profile.samples >= minimumSamples else { return false }
        return profile.averageMB >= heavyThresholdMB
    }

    /// How much memory opening this site will probably cost; 0 when we don't know it well enough.
    public static func predictedBytes(for profile: SiteProfile?) -> UInt64 {
        guard let profile, profile.samples >= minimumSamples else { return 0 }
        return UInt64(profile.averageMB * 1_048_576)
    }

    /// How long a hidden tab may stay awake: heavy sites go to sleep sooner.
    public static func idleLimit(base: TimeInterval, profile: SiteProfile?) -> TimeInterval {
        isHeavy(profile) ? min(base, heavyIdleLimit) : base
    }

    /// The key a site is remembered under: lowercase host without "www.", http(s) only.
    public static func normalizedHost(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}
