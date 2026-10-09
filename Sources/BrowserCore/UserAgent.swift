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
}
