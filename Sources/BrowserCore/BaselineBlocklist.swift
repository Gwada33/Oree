import WebKit

enum BaselineBlocklist {
    static let identifier = "HyperBrowserAdBlock-v1"

    private static let blockedPatterns: [String] = [
        "doubleclick\\.net",
        "googlesyndication\\.com",
        "googleadservices\\.com",
        "google-analytics\\.com",
        "googletagmanager\\.com",
        "googletagservices\\.com",
        "adservice\\.google\\.",
        "facebook\\.com/tr",
        "connect\\.facebook\\.net",
        "amazon-adsystem\\.com",
        "scorecardresearch\\.com",
        "quantserve\\.com",
        "outbrain\\.com",
        "taboola\\.com",
        "criteo\\.com",
        "adnxs\\.com",
        "pubmatic\\.com",
        "rubiconproject\\.com",
        "moatads\\.com",
        "bat\\.bing\\.com",
        "hotjar\\.com",
        "mixpanel\\.com",
        "segment\\.io",
        "branch\\.io",
        "appsflyer\\.com",
        "yieldmo\\.com",
        "adsrvr\\.org",
        "casalemedia\\.com",
    ]

    /// Compiles the baseline list. Used only until the real filter lists
    /// have been downloaded (first launch, offline), so there is never a
    /// window with no protection at all.
    @MainActor
    static func compile() async -> WKContentRuleList? {
        let rules = blockedPatterns.map { pattern in
            ["trigger": ["url-filter": pattern], "action": ["type": "block"]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else { return nil }
        do {
            return try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            )
        } catch {
            Log.network.error("Baseline blocklist compile failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
