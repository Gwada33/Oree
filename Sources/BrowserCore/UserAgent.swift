import Foundation

/// WKWebView's default user agent has no "Version/x Safari/…" part, so Google (and a few other sites)
/// treat it as an unknown, outdated browser and serve their simplified legacy pages. Announcing
/// ourselves as Safari — the engine *is* Safari's — gets the current site.
public enum UserAgent {
    /// The text WebKit appends after "AppleWebKit/… (KHTML, like Gecko)".
    public static func applicationName(safariVersion: String) -> String {
        "Version/\(safariVersion) Safari/605.1.15"
    }

    /// Only the digits and dots of a version string ("27.0", "18.6.1"); anything else falls back.
    public static func sanitizedVersion(_ raw: String?, fallback: String = "18.0") -> String {
        guard let raw, !raw.isEmpty, raw.allSatisfy({ $0.isNumber || $0 == "." }), raw.first?.isNumber == true else { return fallback }
        return raw
    }

    /// The installed Safari's version (matches the WebKit shipped with this macOS).
    public static func installedSafariVersion() -> String {
        let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        let raw = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"]) as? String
        return sanitizedVersion(raw)
    }

    public static var applicationName: String { applicationName(safariVersion: installedSafariVersion()) }

    // MARK: Presenting as another browser

    public static let chromeString = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
    public static let iphoneString = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    public static let firefoxString = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:132.0) Gecko/20100101 Firefox/132.0"

    /// A custom text is kept only if it looks like a user agent: printable ASCII, one line, at most 300 characters.
    public static func isAcceptableCustom(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.count <= 300 && trimmed.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
    }

    /// Whether `host` is `listed` or one of its subdomains, ignoring case and a leading "www.".
    public static func hostMatches(_ host: String?, listed: String) -> Bool {
        func clean(_ text: String) -> String {
            var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value.hasPrefix("www.") { value.removeFirst(4) }
            return value
        }
        guard let host else { return false }
        let h = clean(host), l = clean(listed)
        return !l.isEmpty && (h == l || h.hasSuffix("." + l))
    }

    /// The full user agent to send to `host`, or nil to keep WebKit's own (Safari's). `safari` mode can still present as Chrome on the listed sites.
    public static func override(mode: UserAgentMode, custom: String, host: String?, chromeHosts: [String], mobileHosts: [String] = []) -> String? {
        if mobileHosts.contains(where: { hostMatches(host, listed: $0) }) { return iphoneString }       // a site the user asked for in mobile version
        switch mode {
        case .safari: return chromeHosts.contains { hostMatches(host, listed: $0) } ? chromeString : nil
        case .chrome: return chromeString
        case .firefox: return firefoxString
        case .custom: return isAcceptableCustom(custom) ? custom.trimmingCharacters(in: .whitespaces) : nil
        }
    }
}

public enum UserAgentMode: String, CaseIterable, Sendable {
    case safari, chrome, firefox, custom
    public var label: String {
        switch self {
        case .safari: return "Safari (recommandé)"
        case .chrome: return "Chrome"
        case .firefox: return "Firefox"
        case .custom: return "Personnalisé"
        }
    }
}
