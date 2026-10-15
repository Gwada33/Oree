import Foundation

/// A page read aloud: what to say, and in what pieces (a speech engine handles short passages better than a whole article).
public enum SpeechText {
    /// Title, then the text. Whitespace is collapsed; an empty text gives nothing to read.
    public static func script(title: String, body: String) -> String {
        let text = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return "" }
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return heading.isEmpty ? text : "\(heading). \(text)"
    }

    /// Passages of at most `maxLength` characters, cut at the end of a sentence when there is one, else at a comma or a space.
    public static func chunks(_ text: String, maxLength: Int = 380) -> [String] {
        let clean = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, maxLength > 20 else { return [] }
        var result: [String] = []
        var rest = Substring(clean)
        while !rest.isEmpty {
            if rest.count <= maxLength { result.append(String(rest).trimmingCharacters(in: .whitespaces)); break }
            let window = rest.prefix(maxLength)
            let cut = window.lastIndex(where: { ".?!…".contains($0) }).map { window.index(after: $0) }
                ?? window.lastIndex(where: { ",;:".contains($0) }).map { window.index(after: $0) }
                ?? window.lastIndex(of: " ")
                ?? window.endIndex
            let piece = rest[..<cut]
            result.append(String(piece).trimmingCharacters(in: .whitespaces))
            rest = rest[cut...].drop(while: { $0 == " " })
        }
        return result.filter { !$0.isEmpty }
    }

    /// The language to speak in: the page's `lang` ("fr-FR", "fr", "en_GB") if it is one, else `fallback`.
    public static func language(pageLang: String?, fallback: String) -> String {
        guard let raw = pageLang?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-"), raw.count >= 2, raw.count <= 12,
              raw.allSatisfy({ $0.isLetter || $0 == "-" }) else { return fallback }
        return raw
    }
}
