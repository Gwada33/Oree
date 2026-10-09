import Foundation

/// Sites where the ad / tracker blocking and the fingerprint noise are switched off, because a blocker that
/// only cuts *part* of a site's requests can leave it half-working (mail that never fills in, a video player
/// whose "skip" button never arrives). The user's own list is stored in the settings.
public enum ProtectionPolicy {
    /// Exempt by default: heavy web apps that break when partly blocked.
    public static let defaultExemptHosts = ["mail.google.com", "accounts.google.com", "youtube.com"]

    public static func normalized(_ host: String?) -> String? {
        guard var host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// True when `host` or a parent domain is in `list` (m.youtube.com ← youtube.com).
    public static func isExempt(host: String?, list: [String]) -> Bool {
        guard let host = normalized(host) else { return false }
        return list.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
