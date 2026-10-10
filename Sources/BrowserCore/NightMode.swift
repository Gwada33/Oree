import Foundation

/// When sites are darkened.
public enum NightMode: String, CaseIterable, Sendable, Codable {
    case off        // never
    case auto       // while Orée is dark (it follows the Mac's appearance unless set otherwise)
    case always
}

/// Rules for the night mode that darkens every site (the darkening itself is a page-side filter, see BrowserUI/NightScript).
public enum NightPolicy {
    /// Whether the darkening is on for the given mode and the current appearance.
    public static func isActive(mode: NightMode, appearanceIsDark: Bool) -> Bool {
        switch mode {
        case .off: false
        case .auto: appearanceIsDark
        case .always: true
        }
    }

    /// Hosts are compared without "www." and by domain: excluding "example.com" also covers "news.example.com".
    public static func contains(_ host: String?, in list: [String]) -> Bool {
        ProtectionPolicy.isExempt(host: host, list: list)
    }

    /// Adds `host` (normalized) to `list` unless it is there; the oldest entries go first when the list is full.
    public static func adding(_ host: String?, to list: [String], limit: Int = 300) -> [String] {
        guard let host = ProtectionPolicy.normalized(host), !list.contains(host) else { return list }
        return Array((list + [host]).suffix(limit))
    }

    public static func removing(_ host: String?, from list: [String]) -> [String] {
        guard let host = ProtectionPolicy.normalized(host) else { return list }
        return list.filter { $0 != host }
    }
}
