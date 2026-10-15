import Foundation

/// The address bar finishing what you type ("gith" → "github.com"), like Chrome and Safari do, from the sites you already visit.
public enum InlineCompletion {
    /// Text of an address as the bar shows it: no scheme, no "www.", no trailing slash.
    public static func display(_ address: String) -> String {
        var text = address
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if text.lowercased().hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// The text to put in the bar for `typed`, or nil when nothing fits. `candidates` are addresses, best first (most visited or most
    /// recent). While only a site name is typed, the completion is the site alone ("github.com"); once a "/" is typed, it is the path.
    public static func completion(for typed: String, candidates: [String]) -> String? {
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2, !text.contains(" "), !text.contains("://") else { return nil }
        let lower = text.lowercased()
        let wantsPath = text.contains("/")
        for candidate in candidates {
            let shown = display(candidate)
            let target: String
            if wantsPath {
                target = shown
            } else if let slash = shown.firstIndex(of: "/") {
                target = String(shown[..<slash])
            } else {
                target = shown
            }
            guard target.count > text.count, target.lowercased().hasPrefix(lower) else { continue }
            return text + target.dropFirst(text.count)       // keeps what the user typed, adds the rest
        }
        return nil
    }
}
