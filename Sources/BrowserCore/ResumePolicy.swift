import Foundation

/// Where the user was in a page: the playing position of its video, and how far down they had read.
public struct ResumePoint: Equatable, Sendable, Codable {
    public var key: String
    public var title: String
    public var videoSeconds: Double?
    public var videoDuration: Double?
    /// 0…1 of the scrollable height.
    public var readFraction: Double?
    /// The start of the paragraph at the top of the screen, to find the place again if the page changed a little.
    public var anchor: String?
    public var updatedAt: Date

    public init(key: String, title: String, videoSeconds: Double? = nil, videoDuration: Double? = nil,
                readFraction: Double? = nil, anchor: String? = nil, updatedAt: Date = Date()) {
        self.key = key; self.title = title; self.videoSeconds = videoSeconds; self.videoDuration = videoDuration
        self.readFraction = readFraction; self.anchor = anchor; self.updatedAt = updatedAt
    }
}

/// Rules for "reprendre où tu en étais" (the page-side script only measures; everything that decides lives here).
public enum ResumePolicy {
    /// A video shorter than this is just watched again from the start.
    public static let minimumVideoDuration = 180.0
    /// Before this, the user has hardly started; within `finishedMargin` of the end, they are done.
    public static let minimumVideoPosition = 30.0
    public static let finishedMargin = 20.0
    /// A page is "long" from this many screens; reading counts between these two fractions.
    public static let minimumScreens = 3.0
    public static let readRange = 0.05...0.97
    public static let keepDays = 90
    public static let keepEntries = 500

    private static let noise: Set<String> = ["fbclid", "gclid", "igshid", "mc_cid", "mc_eid", "si", "feature", "t", "time_continue", "start", "ref", "source"]

    /// The page's identity for this feature: no fragment, no tracking or time parameters, no "www.". Web pages only.
    public static func key(for url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = parts.host?.lowercased() else { return nil }
        parts.scheme = scheme
        parts.host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        parts.fragment = nil
        parts.user = nil; parts.password = nil
        let kept = (parts.queryItems ?? []).filter { !$0.name.lowercased().hasPrefix("utm_") && !noise.contains($0.name.lowercased()) }
            .sorted { $0.name < $1.name }
        parts.queryItems = kept.isEmpty ? nil : kept
        return parts.string
    }

    /// Whether a video position is worth keeping. nil/false when it is too early, too late, or the video is short.
    public static func isWorthKeeping(videoSeconds: Double, duration: Double) -> Bool {
        guard videoSeconds.isFinite, duration.isFinite, duration >= minimumVideoDuration else { return false }
        return videoSeconds >= minimumVideoPosition && videoSeconds <= duration - finishedMargin
    }

    /// Whether a scroll position is worth keeping, given the page height in screens.
    public static func isWorthKeeping(readFraction: Double, screens: Double) -> Bool {
        screens >= minimumScreens && readRange.contains(readFraction)
    }

    public static func isExpired(_ point: ResumePoint, now: Date = Date()) -> Bool {
        now.timeIntervalSince(point.updatedAt) > Double(keepDays) * 86_400
    }

    /// "12:34", or "1:02:03" past an hour.
    public static func clock(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// What to offer on return, if anything: the video wins over the reading position.
    public enum Offer: Equatable, Sendable {
        case video(seconds: Double)
        case reading(percent: Int)
    }

    public static func offer(for point: ResumePoint?) -> Offer? {
        guard let point, !isExpired(point) else { return nil }
        if let seconds = point.videoSeconds, let duration = point.videoDuration, isWorthKeeping(videoSeconds: seconds, duration: duration) {
            return .video(seconds: seconds)
        }
        if let fraction = point.readFraction, readRange.contains(fraction) { return .reading(percent: Int((fraction * 100).rounded())) }
        return nil
    }
}
