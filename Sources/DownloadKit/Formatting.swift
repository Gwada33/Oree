import Foundation

/// Human-readable sizes, speeds and times, in French ("124 Mo", "3,2 Mo/s", "2 min restantes").
public enum ByteFormat {
    private static func number(_ value: Double, maxFraction: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maxFraction
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Decimal units like Finder: Ko, Mo, Go, To.
    public static func size(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        switch value {
        case ..<1_000: return "\(Int(value)) o"
        case ..<1_000_000: return "\(number(value / 1_000, maxFraction: 0)) Ko"
        case ..<1_000_000_000: return "\(number(value / 1_000_000, maxFraction: value < 10_000_000 ? 1 : 0)) Mo"
        case ..<1_000_000_000_000: return "\(number(value / 1_000_000_000, maxFraction: 2)) Go"
        default: return "\(number(value / 1_000_000_000_000, maxFraction: 2)) To"
        }
    }

    public static func speed(_ bytesPerSecond: Double) -> String { "\(size(Int64(bytesPerSecond)))/s" }

    public static func remaining(_ seconds: Double) -> String {
        switch seconds {
        case ..<5: return "quelques secondes restantes"
        case ..<60: return "\(Int(seconds.rounded())) s restantes"
        case ..<3_600:
            let minutes = Int((seconds / 60).rounded(.up))
            return "\(minutes) min restante\(minutes > 1 ? "s" : "")"
        case ..<86_400:
            let hours = Int(seconds / 3_600), minutes = Int((seconds.truncatingRemainder(dividingBy: 3_600) / 60).rounded())
            return minutes == 0 ? "\(hours) h restantes" : "\(hours) h \(minutes) min restantes"
        default: return "plus d’un jour restant"
        }
    }

    /// "124 Mo sur 480 Mo · 3,2 Mo/s · 2 min restantes" (parts that are unknown are left out).
    public static func progressLine(_ snapshot: DownloadSnapshot) -> String {
        var parts: [String] = []
        if let total = snapshot.total { parts.append("\(size(snapshot.received)) sur \(size(total))") }
        else { parts.append(size(snapshot.received)) }
        if snapshot.phase == .running, snapshot.bytesPerSecond > 1 { parts.append(speed(snapshot.bytesPerSecond)) }
        if let left = snapshot.secondsRemaining { parts.append(remaining(left)) }
        return parts.joined(separator: " · ")
    }
}

/// Builds the `Cookie` header for a URL from a cookie jar (the browser's WKWebsiteDataStore), RFC 6265 rules:
/// domain match, path prefix, Secure only over https, not expired. Only cookies for THIS host are included.
public enum CookieHeader {
    public static func build(for url: URL, cookies: [HTTPCookie], now: Date = Date()) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let https = url.scheme?.lowercased() == "https"
        let path = url.path.isEmpty ? "/" : url.path
        let matching = cookies.filter { cookie in
            if let expires = cookie.expiresDate, expires <= now { return false }
            if cookie.isSecure && !https { return false }
            guard domainMatches(cookie.domain, host: host), pathMatches(cookie.path, requestPath: path) else { return false }
            return true
        }
        // Longer paths first (RFC 6265 §5.4), then older first.
        let ordered = matching.sorted { ($0.path.count, $1.name) > ($1.path.count, $0.name) }
        let header = ordered.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return header.isEmpty ? nil : header
    }

    static func domainMatches(_ cookieDomain: String, host: String) -> Bool {
        let domain = cookieDomain.lowercased()
        if domain.hasPrefix(".") {
            let bare = String(domain.dropFirst())
            return host == bare || host.hasSuffix(domain)
        }
        return host == domain
    }

    static func pathMatches(_ cookiePath: String, requestPath: String) -> Bool {
        let cookiePath = cookiePath.isEmpty ? "/" : cookiePath
        if requestPath == cookiePath { return true }
        guard requestPath.hasPrefix(cookiePath) else { return false }
        return cookiePath.hasSuffix("/") || requestPath[requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)] == "/"
    }
}
