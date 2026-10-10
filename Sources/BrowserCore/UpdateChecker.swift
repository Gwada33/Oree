import Foundation

/// What the update check needs from a GitHub release. Pure parsing and comparison, no network:
/// the app fetches `https://api.github.com/repos/<owner>/<repo>/releases/latest` and hands the bytes here.
public struct ReleaseInfo: Sendable, Equatable {
    public let version: String
    public let notes: String
    public let downloadURL: URL
    /// The `<zip name>.sha256` file published next to the zip (nil = the release has none).
    public let checksumURL: URL?
}

public enum UpdateChecker {
    public static let repository = "Gwada33/oree"
    public static var latestReleaseURL: URL { URL(string: "https://api.github.com/repos/\(repository)/releases/latest")! }

    /// "v1.2.3" → [1, 2, 3]; anything non-numeric (e.g. "1.2.3-beta") is read up to the first odd character.
    public static func components(of version: String) -> [Int] {
        var text = version.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("v") { text.removeFirst() }
        return text.split(separator: ".").map { part in Int(part.prefix { $0.isNumber }) ?? 0 }
    }

    /// True when `candidate` is strictly newer than `current` (missing parts count as 0: 1.2 == 1.2.0).
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(of: candidate), b = components(of: current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The newest release's version, notes and `.zip` asset, or nil for drafts, pre-releases or a release without a zip.
    public static func parse(_ data: Data) -> ReleaseInfo? {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Release: Decodable { let tag_name: String; let body: String?; let draft: Bool?; let prerelease: Bool?; let assets: [Asset] }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              release.draft != true, release.prerelease != true,
              let zip = release.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }),
              zip.browser_download_url.scheme == "https" else { return nil }
        let checksum = release.assets.first { $0.name == zip.name + ".sha256" && $0.browser_download_url.scheme == "https" }
        return ReleaseInfo(version: release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name,
                           notes: release.body ?? "", downloadURL: zip.browser_download_url, checksumURL: checksum?.browser_download_url)
    }

    /// The 64-hex SHA-256 at the start of a `shasum` line ("<hash>  <file>"), lowercased, or nil if malformed.
    public static func parseChecksum(_ text: String) -> String? {
        guard let first = text.split(whereSeparator: { $0.isWhitespace }).first, first.count == 64,
              first.allSatisfy(\.isHexDigit) else { return nil }
        return first.lowercased()
    }
}
