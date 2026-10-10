import Foundation

/// Recomputes the quantities of a recipe for another number of people ("85 g de beurre" → "170 g de beurre").
///
/// Only the quantity at the start of a line is scaled; "vanille ou 1 sachet de sucre vanillé" or "sel" are left alone, and so is a range
/// ("2 à 3 pommes"), which cannot be scaled without inventing a rule. Plurals are not corrected ("2 oeuf").
public enum IngredientScaler {
    private static let glyphs: [(Character, Double)] = [("½", 0.5), ("¼", 0.25), ("¾", 0.75), ("⅓", 1.0 / 3), ("⅔", 2.0 / 3), ("⅛", 0.125)]

    /// The leading quantity and what follows it; `quantity` is nil when the line starts with no number (or with a range).
    public static func parse(_ line: String) -> (quantity: Double?, rest: String) {
        let text = line.trimmingCharacters(in: .whitespaces)
        // "1 1/2", "1/2", "1,5" / "1.5", "2", then an optional glyph ("1½"), or a glyph alone.
        let patterns: [(String, (NSTextCheckingResult, String) -> Double?)] = [
            (#"^(\d+)\s+(\d+)/(\d+)"#, { m, s in
                guard let w = Double(s.sub(m, 1)), let n = Double(s.sub(m, 2)), let d = Double(s.sub(m, 3)), d != 0 else { return nil }
                return w + n / d }),
            (#"^(\d+)/(\d+)"#, { m, s in
                guard let n = Double(s.sub(m, 1)), let d = Double(s.sub(m, 2)), d != 0 else { return nil }
                return n / d }),
            (#"^(\d+(?:[.,]\d+)?)(?:\s?([½¼¾⅓⅔⅛]))?"#, { m, s in
                guard let whole = Double(s.sub(m, 1).replacingOccurrences(of: ",", with: ".")) else { return nil }
                let glyph = s.sub(m, 2).first.flatMap { g in glyphs.first { $0.0 == g }?.1 } ?? 0
                return whole + glyph }),
            (#"^([½¼¾⅓⅔⅛])"#, { m, s in s.sub(m, 1).first.flatMap { g in glyphs.first { $0.0 == g }?.1 } }),
        ]
        for (pattern, value) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let quantity = value(match, text), let range = Range(match.range, in: text) else { continue }
            let rest = String(text[range.upperBound...])
            // "2 à 3 pommes", "2-3 pommes", "2 ou 3": a range is left as written.
            if rest.range(of: #"^\s*(?:à|a|-|–|ou)\s*\d"#, options: .regularExpression) != nil { return (nil, line) }
            return (quantity, rest)
        }
        return (nil, line)
    }

    /// A quantity as it would be written: whole numbers, simple fractions ("1 ½", "⅓"), else one decimal with a comma ("2,4").
    public static func format(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0" }
        if value >= 10 { return String(Int(value.rounded())) }
        let whole = Int(value.rounded(.down)), fraction = value - Double(whole)
        if fraction < 0.04 { return String(whole) }
        if fraction > 0.96 { return String(whole + 1) }
        if let glyph = glyphs.first(where: { abs($0.1 - fraction) < 0.04 }) {
            return whole == 0 ? String(glyph.0) : "\(whole) \(glyph.0)"
        }
        return String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// The line for `factor` times the original quantities, with the unit and noun put in the right number
    /// ("1 oeuf" ×3 → "3 oeufs", "4 oeufs" ×¼ → "1 oeuf"). French uses the plural from 2 on.
    public static func scaled(_ line: String, factor: Double) -> String {
        let (quantity, rest) = parse(line)
        guard let quantity else { return line }
        let value = quantity * factor
        return format(value) + agree(rest, from: quantity, to: value)
    }

    // MARK: Plural agreement

    /// Words that stand before the noun and agree with it: "1 bonne pincée" → "2 bonnes pincées".
    private static let adjectives: [String: String] = ["bonne": "bonnes", "grosse": "grosses", "petite": "petites", "belle": "belles", "grande": "grandes",
                                                      "gros": "gros", "petit": "petits", "beau": "beaux", "grand": "grands", "bon": "bons", "demi": "demi"]
    /// Written units and invariable words: never changed ("85 g de beurre", "2 c. à soupe").
    private static let invariable: Set<String> = ["g", "kg", "mg", "l", "ml", "cl", "dl", "cm", "mm", "de", "d'", "du", "des", "à", "au", "x", "env.", "et"]
    /// Nouns that end in "s" in the singular.
    private static let singularInS: Set<String> = ["pois", "radis", "anis", "maïs", "cassis", "riz", "jus", "fois", "ananas", "bras", "souris", "thalassémie"]

    /// Puts the first noun of `rest` (and the adjectives before it) in the plural when the quantity went from under 2 to 2 or more, in the
    /// singular for the opposite; unchanged otherwise.
    static func agree(_ rest: String, from old: Double, to new: Double) -> String {
        let wasPlural = old >= 2, isPlural = new >= 2
        guard wasPlural != isPlural else { return rest }
        var words = rest.components(separatedBy: " ")
        for index in words.indices where !words[index].isEmpty {
            let word = words[index], lower = word.lowercased()
            if lower.contains(".") || invariable.contains(lower) { return rest }            // a unit or a link word: nothing to agree
            if adjectives[lower] != nil || adjectives.values.contains(lower) {
                words[index] = isPlural ? (adjectives[lower] ?? word) : singularAdjective(lower)
                continue
            }
            words[index] = isPlural ? plural(word) : singular(word)
            return words.joined(separator: " ")
        }
        return words.joined(separator: " ")
    }

    private static func singularAdjective(_ word: String) -> String {
        adjectives.first { $0.value == word && $0.key != word }?.key ?? word
    }

    private static func plural(_ word: String) -> String {
        let lower = word.lowercased()
        if lower.hasSuffix("s") || lower.hasSuffix("x") || lower.hasSuffix("z") { return word }
        if lower.hasSuffix("eau") { return word + "x" }
        if lower.hasSuffix("al") && lower.count > 3 { return String(word.dropLast(2)) + "aux" }
        return word + "s"
    }

    private static func singular(_ word: String) -> String {
        let lower = word.lowercased()
        if singularInS.contains(lower) || lower.hasSuffix("ss") { return word }
        if lower.hasSuffix("eaux") { return String(word.dropLast()) }
        if lower.hasSuffix("aux") && lower.count > 4 { return String(word.dropLast(3)) + "al" }
        if lower.hasSuffix("s") { return String(word.dropLast()) }
        return word
    }

    /// `table[n - 1][i]` = ingredient `i` for `n` servings, for 1…`maximum`; the original lines at `base`.
    public static func table(for lines: [String], base: Int, maximum: Int) -> [[String]] {
        (1...max(maximum, 1)).map { n in
            n == base ? lines : lines.map { scaled($0, factor: Double(n) / Double(max(base, 1))) }
        }
    }

    /// Whether any line has a quantity to scale (no slider otherwise).
    public static func hasScalableLine(_ lines: [String]) -> Bool { lines.contains { parse($0).quantity != nil } }
}

private extension String {
    func sub(_ match: NSTextCheckingResult, _ group: Int) -> String {
        guard group < match.numberOfRanges, let range = Range(match.range(at: group), in: self) else { return "" }
        return String(self[range])
    }
}
