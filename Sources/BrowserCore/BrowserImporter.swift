import Foundation

/// Other browsers this can import bookmarks from. Deliberately scoped to
/// bookmarks only for now:
///  - History/cookies live in locked SQLite databases the source browser has
///    open while running, and Safari's live under Full Disk Access — doable
///    later, but a bigger, separate piece of work.
///  - Passwords are NOT read from another browser's storage here. Chrome and
///    Safari both encrypt saved passwords behind the macOS Keychain with
///    per-app access control for exactly this reason — code that silently
///    reaches into another app's credential store is indistinguishable from
///    a credential-stealing tool, authorized or not. The legitimate path is
///    each browser's own "Export Passwords" (CSV) feature; HyperBrowser has
///    no password manager to import *into* yet either, so that's its own
///    future feature, built the same way every password manager does it.
/// A bookmark read from another browser's own file — deliberately not the
/// storage layer's `Bookmark` record, so `BrowserCore` doesn't need to
/// depend on `BrowserStorage` just to import things. Callers convert this
/// into a real stored bookmark.
public struct ImportedBookmark: Sendable {
    public let url: String
    public let title: String
}

public enum SourceBrowser: String, CaseIterable, Sendable {
    case safari
    case chrome
    case brave
    case edge

    public var displayName: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Chrome"
        case .brave: return "Brave"
        case .edge: return "Edge"
        }
    }

    fileprivate var bookmarksFileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .safari:
            return home.appendingPathComponent("Library/Safari/Bookmarks.plist")
        case .chrome:
            return home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Bookmarks")
        case .brave:
            return home.appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser/Default/Bookmarks")
        case .edge:
            return home.appendingPathComponent("Library/Application Support/Microsoft Edge/Default/Bookmarks")
        }
    }
}

public enum BrowserImporter {
    public static func detectInstalledBrowsers() -> [SourceBrowser] {
        SourceBrowser.allCases.filter { FileManager.default.fileExists(atPath: $0.bookmarksFileURL.path) }
    }

    public static func importBookmarks(from browser: SourceBrowser) -> [ImportedBookmark] {
        guard let data = try? Data(contentsOf: browser.bookmarksFileURL) else { return [] }
        switch browser {
        case .safari:
            return parseSafariBookmarks(data)
        case .chrome, .brave, .edge:
            return parseChromiumBookmarks(data)
        }
    }

    // MARK: - Safari (property list)

    private static func parseSafariBookmarks(_ data: Data) -> [ImportedBookmark] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return []
        }
        var results: [ImportedBookmark] = []
        walkSafariNode(root, into: &results)
        return results
    }

    private static func walkSafariNode(_ node: [String: Any], into results: inout [ImportedBookmark]) {
        if let type = node["WebBookmarkType"] as? String, type == "WebBookmarkTypeLeaf",
           let url = node["URLString"] as? String {
            let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? url
            results.append(ImportedBookmark(url: url, title: title))
        }
        if let children = node["Children"] as? [[String: Any]] {
            for child in children {
                walkSafariNode(child, into: &results)
            }
        }
    }

    // MARK: - Chromium family (JSON)

    private static func parseChromiumBookmarks(_ data: Data) -> [ImportedBookmark] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else {
            return []
        }
        var results: [ImportedBookmark] = []
        for (_, value) in roots {
            if let node = value as? [String: Any] {
                walkChromiumNode(node, into: &results)
            }
        }
        return results
    }

    private static func walkChromiumNode(_ node: [String: Any], into results: inout [ImportedBookmark]) {
        let type = node["type"] as? String
        if type == "url", let url = node["url"] as? String {
            let title = node["name"] as? String ?? url
            results.append(ImportedBookmark(url: url, title: title))
        } else if let children = node["children"] as? [[String: Any]] {
            for child in children {
                walkChromiumNode(child, into: &results)
            }
        }
    }
}
