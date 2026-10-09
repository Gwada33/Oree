import Foundation

/// Strips tracking parameters (utm_*, fbclid, gclid, ...) from URLs using the
/// ClearURLs rule format. Only the *query string* and a few well-known
/// redirect wrappers are touched; everything else in the URL is preserved
/// byte for byte, so a URL with nothing to clean comes back identical.
public struct URLCleaner: Sendable {
    private struct Provider: Decodable {
        let urlPattern: String
        let rules: [String]?
        let referralMarketing: [String]?
        let rawRules: [String]?
        let exceptions: [String]?
        let redirections: [String]?
    }

    private struct Document: Decodable {
        let providers: [String: Provider]
    }

    /// `NSRegularExpression` is immutable after creation and documented
    /// thread-safe, so sharing the compiled form across threads is fine.
    private struct CompiledProvider: @unchecked Sendable {
        let urlPattern: NSRegularExpression
        let paramRules: [NSRegularExpression]
        let rawRules: [NSRegularExpression]
        let exceptions: [NSRegularExpression]
        let redirections: [NSRegularExpression]
    }

    private let providers: [CompiledProvider]

    /// The rule set shipped inside the app.
    public static let bundled: URLCleaner = {
        guard let data = ClearURLsSnapshot.json.data(using: .utf8),
              let cleaner = try? URLCleaner(jsonData: data) else {
            return URLCleaner(providers: [])
        }
        return cleaner
    }()

    private init(providers: [CompiledProvider]) {
        self.providers = providers
    }

    /// - Parameter includeReferralMarketing: ClearURLs separates plain
    ///   tracking parameters from "referral marketing" ones (affiliate tags,
    ///   `ref=`) because removing the latter can cost a site's author their
    ///   attribution. Off by default, same as ClearURLs.
    public init(jsonData: Data, includeReferralMarketing: Bool = false) throws {
        let document = try JSONDecoder().decode(Document.self, from: jsonData)

        func compile(_ patterns: [String]?, anchored: Bool = false) -> [NSRegularExpression] {
            (patterns ?? []).compactMap { pattern in
                let source = anchored ? "^(?:\(pattern))$" : pattern
                // A rule written for JavaScript regexes that ICU rejects is
                // skipped on its own rather than discarding its provider.
                return try? NSRegularExpression(pattern: source, options: [.caseInsensitive])
            }
        }

        providers = document.providers.values.compactMap { provider in
            guard let urlPattern = try? NSRegularExpression(pattern: provider.urlPattern, options: [.caseInsensitive]) else {
                return nil
            }
            let paramPatterns = (provider.rules ?? []) + (includeReferralMarketing ? (provider.referralMarketing ?? []) : [])
            return CompiledProvider(
                urlPattern: urlPattern,
                paramRules: compile(paramPatterns, anchored: true),
                rawRules: compile(provider.rawRules),
                exceptions: compile(provider.exceptions),
                redirections: compile(provider.redirections)
            )
        }
    }

    /// Returns `url` with tracking removed, or `url` itself if nothing applied.
    public func clean(_ url: URL) -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return url }
        // Redirect unwrapping can in theory chain; bound it.
        var current = url
        for _ in 0..<3 {
            let next = cleanOnce(current)
            if next == current { return next }
            current = next
        }
        return current
    }

    private func cleanOnce(_ url: URL) -> URL {
        var text = url.absoluteString
        let original = text

        for provider in providers {
            let range = NSRange(text.startIndex..., in: text)
            guard provider.urlPattern.firstMatch(in: text, range: range) != nil else { continue }
            if provider.exceptions.contains(where: { $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }) {
                continue
            }

            // Wrapper links ("google.com/url?q=<target>"): jump straight to the target.
            for redirection in provider.redirections {
                let searchRange = NSRange(text.startIndex..., in: text)
                if let match = redirection.firstMatch(in: text, range: searchRange),
                   match.numberOfRanges > 1,
                   let captured = Range(match.range(at: 1), in: text),
                   let decoded = String(text[captured]).removingPercentEncoding,
                   let target = URL(string: decoded),
                   let targetScheme = target.scheme?.lowercased(),
                   targetScheme == "http" || targetScheme == "https" {
                    return target
                }
            }

            for raw in provider.rawRules {
                let rawRange = NSRange(text.startIndex..., in: text)
                text = raw.stringByReplacingMatches(in: text, range: rawRange, withTemplate: "")
            }

            text = removingParameters(from: text, matching: provider.paramRules)
        }

        return text == original ? url : (URL(string: text) ?? url)
    }

    /// Drops query parameters whose *name* matches a rule. Works on the
    /// still-percent-encoded query so surviving parameters aren't re-encoded.
    private func removingParameters(from urlString: String, matching rules: [NSRegularExpression]) -> String {
        guard !rules.isEmpty else { return urlString }

        // Split off the fragment first: a "?" inside "#/route?x=1" belongs to
        // the fragment, not to the query string.
        let hashIndex = urlString.firstIndex(of: "#")
        let head = hashIndex.map { urlString[..<$0] } ?? urlString[...]
        let fragment = hashIndex.map { String(urlString[$0...]) } ?? ""
        guard let queryStart = head.firstIndex(of: "?") else { return urlString }

        let query = head[head.index(after: queryStart)...]
        let kept = query.split(separator: "&", omittingEmptySubsequences: true).filter { pair in
            let rawName = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let name = rawName.removingPercentEncoding ?? rawName
            let nameRange = NSRange(name.startIndex..., in: name)
            return !rules.contains { $0.firstMatch(in: name, range: nameRange) != nil }
        }

        let base = String(head[..<queryStart])
        return kept.isEmpty ? base + fragment : base + "?" + kept.joined(separator: "&") + fragment
    }
}
