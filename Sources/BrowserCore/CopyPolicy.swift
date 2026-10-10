import Foundation

/// Rules about what was just copied from a page (the page-side script does the copying itself).
public enum CopyPolicy {
    /// Longer than this, or on more lines, it is a paragraph that merely mentions an address, not an address.
    static let maxAddressLength = 200
    static let maxAddressLines = 3

    /// The postal address if the copied text is, as a whole, one address ("12 rue de Rivoli, 75001 Paris").
    public static func postalAddress(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8, trimmed.count <= maxAddressLength,
              trimmed.split(whereSeparator: \.isNewline).count <= maxAddressLines,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue) else { return nil }
        let whole = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = detector.firstMatch(in: trimmed, options: [], range: whole), match.resultType == .address else { return nil }
        // "Meet me at 10 Downing Street, London at 6": the address is only part of it, so no offer.
        return Double(match.range.length) >= 0.8 * Double(whole.length) ? trimmed : nil
    }

    /// Opens Apple Maps (the `maps:` scheme, so it never lands in the browser itself) on `address`.
    public static func mapsURL(for address: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "maps"
        parts.host = ""
        parts.queryItems = [URLQueryItem(name: "q", value: address.replacingOccurrences(of: "\n", with: ", "))]
        return parts.url
    }
}
