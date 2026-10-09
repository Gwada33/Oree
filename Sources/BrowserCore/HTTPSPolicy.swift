import Foundation

public enum HTTPSDecision: Equatable, Sendable {
    case allow
    case upgrade(to: URL)
}

/// HTTPS-only mode: plain `http://` main-frame navigations are upgraded to
/// `https://`. If the upgraded load then fails in a way that suggests the
/// site simply doesn't speak TLS, the UI warns before offering HTTP.
public struct HTTPSPolicy: Sendable {
    public var isEnabled: Bool

    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    /// - Parameter exemptHosts: hosts the user already chose to open over
    ///   HTTP this session, so a fallback doesn't get upgraded again in a loop.
    public func decision(for url: URL, exemptHosts: Set<String> = []) -> HTTPSDecision {
        guard isEnabled,
              url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(),
              !exemptHosts.contains(host),
              !Self.isLocalOrPrivate(host: host),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .allow
        }
        components.scheme = "https"
        // An explicit :80 only made sense for HTTP.
        if components.port == 80 { components.port = nil }
        guard let upgraded = components.url else { return .allow }
        return .upgrade(to: upgraded)
    }

    /// Errors after which offering plain HTTP is reasonable: the server can't
    /// be reached over TLS at all. Certificate errors are deliberately
    /// excluded — "continue over HTTP" would turn a security warning into a
    /// silent downgrade — and so are DNS failures, which HTTP wouldn't fix.
    public static func shouldOfferHTTPFallback(for error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch nsError.code {
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorCannotConnectToHost,
             NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost:
            return true
        default:
            return false
        }
    }

    /// Hosts that routinely have no HTTPS: loopback, intranet names, mDNS
    /// (`.local`), and RFC 1918 private ranges.
    static func isLocalOrPrivate(host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if host == "::1" || host == "[::1]" { return true }
        if !host.contains(".") && !host.contains(":") { return true }

        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        case (169, 254): return true
        default: return false
        }
    }
}
