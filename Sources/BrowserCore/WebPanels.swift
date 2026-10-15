import Foundation

/// A web app kept in a side panel (WhatsApp Web, a calendar, a chat…): a name and an address.
public struct WebPanelEntry: Codable, Equatable, Sendable {
    public var name: String
    public var url: String
    public init(name: String, url: String) { self.name = name; self.url = url }
}

public enum WebPanels {
    public static let limit = 12

    /// Suggestions offered when the list is empty (addresses the sites publish themselves).
    public static let suggestions: [WebPanelEntry] = [
        WebPanelEntry(name: "WhatsApp", url: "https://web.whatsapp.com/"),
        WebPanelEntry(name: "Google Agenda", url: "https://calendar.google.com/"),
        WebPanelEntry(name: "Notion", url: "https://www.notion.so/"),
    ]

    /// What the user typed → a web address: "notion.so" becomes https://notion.so/. Only http(s) pages with a host qualify.
    public static func normalize(_ text: String) -> URL? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains(" ") else { return nil }
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, host.contains(".") else { return nil }
        return url
    }

    /// "web.whatsapp.com" → "Whatsapp": the host without "www."/"web." and its extension, capitalised.
    public static func defaultName(for url: URL) -> String {
        var parts = (url.host ?? "").split(separator: ".").map(String.init)
        if parts.count > 2, ["www", "web", "app", "m"].contains(parts[0]) { parts.removeFirst() }
        let core = parts.count >= 2 ? parts[parts.count - 2] : (parts.first ?? "Web")
        return core.prefix(1).uppercased() + core.dropFirst()
    }

    /// Adds an entry (same address twice: the new name wins), within the limit.
    public static func adding(_ entry: WebPanelEntry, to list: [WebPanelEntry]) -> [WebPanelEntry] {
        Array((list.filter { $0.url != entry.url } + [entry]).prefix(limit))
    }
}
