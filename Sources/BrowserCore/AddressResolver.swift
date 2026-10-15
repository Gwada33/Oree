import Foundation

/// A search shortcut: type `keyword`, a space, then your words, and the search goes to this site ("w paris" → Wikipédia).
public struct SearchShortcut: Equatable, Sendable, Codable, Identifiable {
    public var id: String { keyword }
    public var name: String
    public var keyword: String
    /// Address with `%s` where the words go.
    public var template: String

    public init(name: String, keyword: String, template: String) { self.name = name; self.keyword = keyword; self.template = template }

    /// Whether this can be saved: a short keyword with no space, and an https/http address containing `%s`.
    public var isValid: Bool {
        let key = keyword.trimmingCharacters(in: .whitespaces)
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !key.isEmpty, !key.contains(where: \.isWhitespace), key.count <= 12,
              template.contains("%s"), let url = URL(string: template.replacingOccurrences(of: "%s", with: "x")) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }
}

/// What typed text means: an address to open, or a search.
public enum AddressResolution: Equatable, Sendable {
    case address(URL)
    /// `site` names where the search goes ("Google", "Wikipédia").
    case search(site: String, url: URL)

    public var url: URL { switch self { case .address(let url), .search(_, let url): return url } }
}

public enum AddressResolver {
    /// Shortcuts every install has. Custom shortcuts with the same keyword win.
    public static let builtInShortcuts: [SearchShortcut] = [
        SearchShortcut(name: "Wikipédia", keyword: "w", template: "https://fr.wikipedia.org/w/index.php?search=%s"),
        SearchShortcut(name: "YouTube", keyword: "yt", template: "https://www.youtube.com/results?search_query=%s"),
        SearchShortcut(name: "GitHub", keyword: "gh", template: "https://github.com/search?q=%s"),
        SearchShortcut(name: "Stack Overflow", keyword: "so", template: "https://stackoverflow.com/search?q=%s"),
        SearchShortcut(name: "Google Maps", keyword: "maps", template: "https://www.google.com/maps/search/%s"),
        SearchShortcut(name: "Google", keyword: "g", template: SearchEngine.google.template),
        SearchShortcut(name: "DuckDuckGo", keyword: "ddg", template: SearchEngine.duckduckgo.template),
        SearchShortcut(name: "Bing", keyword: "b", template: SearchEngine.bing.template),
        SearchShortcut(name: "Brave Search", keyword: "br", template: SearchEngine.brave.template),
        SearchShortcut(name: "Qwant", keyword: "q", template: SearchEngine.qwant.template),
    ]

    /// Whether typed text should be opened as an address rather than searched.
    public static func looksLikeAddress(_ text: String) -> Bool {
        if text.contains(" ") { return false }
        if text.contains("://") { return true }
        if text.hasPrefix("localhost") { return true }
        if text.range(of: #"^[\w.-]+:\d{2,5}(/.*)?$"#, options: .regularExpression) != nil { return true }
        return text.contains(".")
    }

    /// The words, made safe to sit inside a query parameter: `&`, `=`, `+`, `#` and the like are encoded, unlike `.urlQueryAllowed`.
    public static func encodeQuery(_ words: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return words.addingPercentEncoding(withAllowedCharacters: allowed) ?? words
    }

    public static func resolve(_ raw: String, defaultEngine: SearchEngine, custom: [SearchShortcut] = []) -> AddressResolution? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // "keyword words": the keyword is the first word and there must be words after it.
        if let space = text.firstIndex(where: \.isWhitespace) {
            let keyword = text[..<space].lowercased()
            let words = text[space...].trimmingCharacters(in: .whitespacesAndNewlines)
            let shortcuts = custom.filter(\.isValid) + builtInShortcuts
            if !words.isEmpty, let shortcut = shortcuts.first(where: { $0.keyword.lowercased() == keyword }),
               let url = URL(string: shortcut.template.replacingOccurrences(of: "%s", with: encodeQuery(words))) {
                return .search(site: shortcut.name, url: url)
            }
        }

        if text.contains("://") {
            return URL(string: text).map(AddressResolution.address)
        }
        if looksLikeAddress(text) {
            // localhost / host:port are dev servers that rarely speak TLS.
            let isLocal = text.hasPrefix("localhost") || text.range(of: #"^[\w.-]+:\d{2,5}"#, options: .regularExpression) != nil
            return URL(string: "\(isLocal ? "http" : "https")://\(text)").map(AddressResolution.address)
        }
        return URL(string: defaultEngine.template.replacingOccurrences(of: "%s", with: encodeQuery(text)))
            .map { AddressResolution.search(site: defaultEngine.shortName, url: $0) }
    }
}
