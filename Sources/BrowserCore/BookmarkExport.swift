import Foundation

/// Bookmarks as the HTML file every browser imports (the "Netscape bookmark file" format Chrome, Safari and Firefox read and write).
public enum BookmarkExport {
    public struct Item: Equatable, Sendable {
        public var title: String
        public var url: String
        public var folder: String
        public var added: Date?
        public init(title: String, url: String, folder: String, added: Date? = nil) { self.title = title; self.url = url; self.folder = folder; self.added = added }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Only web addresses are written (a `javascript:` bookmark must not travel to another browser). Folders keep their first-seen order.
    public static func html(_ items: [Item]) -> String {
        let usable = items.filter { item in
            guard let url = URL(string: item.url), let scheme = url.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https"
        }
        var folders: [String] = []
        for item in usable where !folders.contains(item.folder) { folders.append(item.folder) }
        var lines = ["<!DOCTYPE NETSCAPE-Bookmark-file-1>",
                     "<!-- This is an automatically generated file. It will be read and overwritten. DO NOT EDIT! -->",
                     "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
                     "<TITLE>Bookmarks</TITLE>", "<H1>Bookmarks</H1>", "<DL><p>"]
        for folder in folders {
            lines.append("    <DT><H3>\(escape(folder))</H3>")
            lines.append("    <DL><p>")
            for item in usable where item.folder == folder {
                let date = item.added.map { " ADD_DATE=\"\(Int($0.timeIntervalSince1970))\"" } ?? ""
                lines.append("        <DT><A HREF=\"\(escape(item.url))\"\(date)>\(escape(item.title.isEmpty ? item.url : item.title))</A>")
            }
            lines.append("    </DL><p>")
        }
        lines.append("</DL><p>")
        return lines.joined(separator: "\n") + "\n"
    }
}
