import Foundation

/// A tab that went to the archive because nobody touched it for a while: enough to bring it back.
public struct ArchivedTab: Codable, Equatable, Sendable {
    public var url: String
    public var title: String
    public var space: Int
    public var archivedAt: Date
    public init(url: String, title: String, space: Int, archivedAt: Date) {
        self.url = url; self.title = title; self.space = space; self.archivedAt = archivedAt
    }
}

/// Which tabs the archive takes, and what the archive keeps.
public enum TabArchivePolicy {
    /// After how long a tab that nobody uses is archived (0 = never, the default).
    public static let periods: [Int] = [0, 1, 7, 30]
    public static let limit = 200

    /// `days` = 0 never archives. A tab is stale after `days` full days without being in front.
    public static func isStale(idle: TimeInterval, days: Int) -> Bool {
        days > 0 && idle >= TimeInterval(days) * 86_400
    }

    /// Only ordinary web pages: never the one in front, one that plays sound, a private tab, or a page with no address.
    public static func canArchive(url: URL?, isPrivate: Bool, isActive: Bool, playsAudio: Bool) -> Bool {
        guard !isPrivate, !isActive, !playsAudio, let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Newest first, one entry per address (archiving a page again moves it up), at most `limit`.
    public static func adding(_ tab: ArchivedTab, to list: [ArchivedTab]) -> [ArchivedTab] {
        Array(([tab] + list.filter { $0.url != tab.url }).prefix(limit))
    }
}

/// The archive on disk (a small JSON in the preferences: a few hundred lines at most).
public struct TabArchiveStore: Sendable {
    private let key: String
    public init(key: String = "tabArchive.v1") { self.key = key }

    public func load(_ defaults: UserDefaults = .standard) -> [ArchivedTab] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ArchivedTab].self, from: data)) ?? []
    }
    public func save(_ list: [ArchivedTab], _ defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(list), forKey: key)
    }
}
