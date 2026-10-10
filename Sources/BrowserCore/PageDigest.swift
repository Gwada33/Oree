import Foundation

/// The essentials of a page ("l'essentiel"): a recipe's ingredients and steps, a tutorial's steps, a comparison's verdict.
public struct PageDigest: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case recipe, tutorial, review, other }
    /// Where it came from: read exactly from the page's own structured data, or written by the local model.
    public enum Source: String, Codable, Sendable { case structured, model }

    public var kind: Kind
    public var title: String
    public var summary: String?
    public var times: [String]
    public var ingredients: [String]
    public var steps: [String]
    public var verdict: String?
    public var pros: [String]
    public var cons: [String]
    public var source: Source
    /// How many people (or pieces) the recipe is for, and what they are called ("personnes", "crêpes"); drives the servings slider.
    public var servings: Int?
    public var servingsLabel: String?

    public init(kind: Kind, title: String, summary: String? = nil, times: [String] = [], ingredients: [String] = [], steps: [String] = [],
                verdict: String? = nil, pros: [String] = [], cons: [String] = [], source: Source, servings: Int? = nil, servingsLabel: String? = nil) {
        self.kind = kind; self.title = title; self.summary = summary; self.times = times; self.ingredients = ingredients
        self.steps = steps; self.verdict = verdict; self.pros = pros; self.cons = cons; self.source = source
        self.servings = servings; self.servingsLabel = servingsLabel
    }

    /// Worth showing: something that can be cooked, followed or decided from.
    public var hasContent: Bool { !ingredients.isEmpty || !steps.isEmpty || !(verdict ?? "").isEmpty }
}

public enum DigestParser {
    // MARK: The page's own structured data (schema.org JSON-LD)

    /// Reads the first Recipe or HowTo in a page's JSON-LD blocks (each string is one `<script type="application/ld+json">`).
    public static func fromStructuredData(_ blocks: [String], pageTitle: String) -> PageDigest? {
        for block in blocks {
            guard let data = block.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            for node in nodes(in: json) {
                let types = typeNames(of: node)
                if types.contains("Recipe"), let digest = recipe(node, pageTitle: pageTitle) { return digest }
                if types.contains("HowTo"), let digest = howTo(node, pageTitle: pageTitle) { return digest }
            }
        }
        return nil
    }

    /// Every dictionary in a JSON-LD document: a single object, an array, or an `@graph`.
    private static func nodes(in json: Any) -> [[String: Any]] {
        if let array = json as? [Any] { return array.flatMap(nodes(in:)) }
        guard let object = json as? [String: Any] else { return [] }
        return [object] + (object["@graph"].map(nodes(in:)) ?? [])
    }

    private static func typeNames(of node: [String: Any]) -> [String] {
        if let one = node["@type"] as? String { return [one] }
        return (node["@type"] as? [String]) ?? []
    }

    private static func recipe(_ node: [String: Any], pageTitle: String) -> PageDigest? {
        let ingredients = strings(node["recipeIngredient"] ?? node["ingredients"])
        let steps = instructions(node["recipeInstructions"])
        guard !ingredients.isEmpty || !steps.isEmpty else { return nil }
        var times: [String] = []
        for (key, label) in [("prepTime", "Préparation"), ("cookTime", "Cuisson"), ("totalTime", "Total")] {
            if let text = node[key] as? String, let formatted = formatDuration(text) { times.append("\(label) : \(formatted)") }
        }
        // "4 personnes" → a slider (4, "personnes"); a yield with no number stays a plain line.
        var servings: Int?, label: String?
        if let yield = yieldText(node["recipeYield"]) {
            if let parsed = parseYield(yield), !ingredients.isEmpty { (servings, label) = (parsed.count, parsed.label) } else { times.append("Pour : \(yield)") }
        }
        return PageDigest(kind: .recipe, title: clean(node["name"] as? String) ?? pageTitle, summary: clean(node["description"] as? String),
                          times: times, ingredients: ingredients, steps: steps, source: .structured, servings: servings, servingsLabel: label)
    }

    private static func howTo(_ node: [String: Any], pageTitle: String) -> PageDigest? {
        let steps = instructions(node["step"])
        guard !steps.isEmpty else { return nil }
        var times: [String] = []
        if let text = node["totalTime"] as? String, let formatted = formatDuration(text) { times.append("Durée : \(formatted)") }
        return PageDigest(kind: .tutorial, title: clean(node["name"] as? String) ?? pageTitle, summary: clean(node["description"] as? String),
                          times: times, ingredients: strings(node["supply"]) + strings(node["tool"]), steps: steps, source: .structured)
    }

    /// Strings from "a", ["a", "b"] or [{"name": "a"}] — with HTML tags and entities removed.
    private static func strings(_ value: Any?) -> [String] {
        switch value {
        case let text as String: return clean(text).map { [$0] } ?? []
        case let array as [Any]: return array.flatMap { strings($0) }
        case let object as [String: Any]: return strings(object["name"] ?? object["text"])
        default: return []
        }
    }

    /// Steps from a string, a list of strings, HowToStep objects, or HowToSection objects holding steps.
    private static func instructions(_ value: Any?) -> [String] {
        switch value {
        case let text as String:
            let lines = text.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "</li>", with: "\n").components(separatedBy: .newlines)
            return lines.compactMap(clean)
        case let array as [Any]: return array.flatMap(instructions)
        case let object as [String: Any]:
            if let sub = object["itemListElement"] { return instructions(sub) }
            return strings(object["text"] ?? object["name"])
        default: return []
        }
    }

    private static func yieldText(_ value: Any?) -> String? {
        switch value {
        case let text as String: return clean(text)
        case let number as NSNumber: return "\(number)"
        case let array as [Any]: return array.compactMap(yieldText).first
        default: return nil
        }
    }

    /// "4 personnes" → (4, "personnes"); "12 crêpes" → (12, "crêpes"); "6" → (6, "personnes"). nil when there is no sensible number.
    public static func parseYield(_ text: String) -> (count: Int, label: String)? {
        let matches = text.matches(of: /\d+/)
        guard let first = matches.first, let count = Int(first.output), (1...100).contains(count), let last = matches.last else { return nil }
        let after = text[last.range.upperBound...].trimmingCharacters(in: CharacterSet.letters.inverted)
        return (count, after.isEmpty ? "personnes" : after)
    }

    // MARK: Text helpers

    /// Removes tags, decodes the few entities pages use, collapses spaces; nil when nothing is left.
    public static func clean(_ text: String?) -> String? {
        guard var value = text else { return nil }
        value = value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            value = value.replacingOccurrences(of: entity, with: char)
        }
        value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// "PT1H30M" → "1 h 30 min"; "P1DT2H" → "1 j 2 h"; nil when it is not an ISO-8601 duration or is zero.
    public static func formatDuration(_ iso: String) -> String? {
        guard let match = iso.range(of: "^P(?:(\\d+)D)?(?:T(?:(\\d+)H)?(?:(\\d+)M)?(?:(\\d+)S)?)?$", options: .regularExpression) else { return nil }
        let text = String(iso[match])
        func number(_ unit: Character) -> Int {
            guard let r = text.range(of: "(\\d+)\(unit)", options: .regularExpression) else { return 0 }
            return Int(text[r].dropLast()) ?? 0
        }
        // "M" means months before the "T" and minutes after it: only the time part has minutes here.
        let timePart = text.split(separator: "T", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        func timeNumber(_ unit: Character) -> Int {
            guard let r = timePart.range(of: "(\\d+)\(unit)", options: .regularExpression) else { return 0 }
            return Int(timePart[r].dropLast()) ?? 0
        }
        let days = number("D"), hours = timeNumber("H"), minutes = timeNumber("M"), seconds = timeNumber("S")
        var parts: [String] = []
        if days > 0 { parts.append("\(days) j") }
        if hours > 0 { parts.append("\(hours) h") }
        if minutes > 0 { parts.append("\(minutes) min") }
        if parts.isEmpty, seconds > 0 { parts.append("\(seconds) s") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: What the local model wrote

    /// Reads the model's JSON answer, even wrapped in a code fence or followed by chatter. Keys are matched loosely
    /// (accents, case): "INGRÉDIENTS", "ingredients" and "Ingrédients" are the same.
    public static func fromModel(_ answer: String, pageTitle: String) -> PageDigest? {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let data = String(answer[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var fields: [String: Any] = [:]
        for (key, value) in object { fields[fold(key)] = value }

        let kind = (fields["type"] as? String).map(fold).flatMap { value -> PageDigest.Kind? in
            if value.contains("recette") || value.contains("recipe") { return .recipe }
            if value.contains("tuto") || value.contains("guide") || value.contains("howto") { return .tutorial }
            if value.contains("compar") || value.contains("test") || value.contains("review") || value.contains("avis") { return .review }
            return nil
        }
        let ingredients = strings(fields["ingredients"])
        let steps = strings(fields["etapes"] ?? fields["steps"] ?? fields["instructions"])
        let verdict = clean(fields["verdict"] as? String ?? fields["conclusion"] as? String)
        var times: [String] = []
        if let text = fields["temps"] ?? fields["times"] {
            times = text is String ? (clean(text as? String).map { [$0] } ?? []) : strings(text)
        }
        let inferred: PageDigest.Kind = kind ?? (!ingredients.isEmpty ? .recipe : (verdict != nil ? .review : (!steps.isEmpty ? .tutorial : .other)))
        let digest = PageDigest(kind: inferred, title: clean(fields["titre"] as? String ?? fields["title"] as? String) ?? pageTitle,
                                summary: clean(fields["resume"] as? String ?? fields["summary"] as? String), times: times,
                                ingredients: ingredients, steps: steps, verdict: verdict,
                                pros: strings(fields["pour"] ?? fields["avantages"] ?? fields["pros"]),
                                cons: strings(fields["contre"] ?? fields["inconvenients"] ?? fields["cons"]), source: .model)
        return digest.hasContent ? digest : nil
    }

    /// Lowercase, no accents, no punctuation: "Étapes" and "etapes" are one key.
    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

/// The model sometimes invents or translates: an item is kept only when most of its words are in the page's own text.
public enum DigestValidator {
    /// Words long enough to mean something (four letters or more), folded.
    static func significantWords(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 4 }
    }

    /// Items whose significant words are at least `threshold` present in `source`; items with no such word are kept as they are.
    public static func supported(_ items: [String], by source: String, threshold: Double = 0.5) -> [String] {
        let known = Set(significantWords(source))
        return items.filter { item in
            let words = significantWords(item)
            guard !words.isEmpty else { return true }
            return Double(words.filter { known.contains($0) }.count) / Double(words.count) >= threshold
        }
    }

    /// The digest without what the page does not support, and how many items were dropped.
    public static func checked(_ digest: PageDigest, against source: String) -> (digest: PageDigest, dropped: Int) {
        var result = digest
        result.ingredients = supported(digest.ingredients, by: source)
        result.steps = supported(digest.steps, by: source)
        result.pros = supported(digest.pros, by: source)
        result.cons = supported(digest.cons, by: source)
        if let verdict = digest.verdict, supported([verdict], by: source, threshold: 0.4).isEmpty { result.verdict = nil }
        let dropped = (digest.ingredients.count - result.ingredients.count) + (digest.steps.count - result.steps.count)
            + (digest.pros.count - result.pros.count) + (digest.cons.count - result.cons.count) + (digest.verdict != nil && result.verdict == nil ? 1 : 0)
        return (result, dropped)
    }

    /// What goes to the model: the page's text cut to what fits its small context (start and end, where recipes, steps and verdicts are).
    public static func budget(_ text: String, characters: Int = 6000) -> String {
        guard text.count > characters else { return text }
        let head = Int(Double(characters) * 0.45)
        return String(text.prefix(head)) + "\n[…]\n" + String(text.suffix(characters - head))
    }
}

/// What the local model is asked.
public enum DigestPrompt {
    public static let instructions = """
    Tu lis le texte d'une page web et tu en extrais l'essentiel. Réponds uniquement avec un objet JSON, sans aucun texte autour. \
    Clés : "type" ("recette", "tutoriel", "comparatif" ou "autre"), "titre", "ingredients" (liste, vide si absent), \
    "etapes" (liste d'instructions courtes), "temps" (texte, par exemple "Préparation : 10 min, cuisson : 20 min", vide si absent), \
    "verdict" (une ou deux phrases : la conclusion ou la recommandation de l'auteur, vide si absente), \
    "pour" et "contre" (listes courtes, vides si absentes). \
    Écris dans la langue du texte de la page, sans la traduire. N'invente rien : si une information n'est pas dans le texte, laisse le champ vide.
    """

    public static func prompt(title: String, text: String) -> String {
        "Titre de la page : \(title)\n\nTexte de la page :\n\(DigestValidator.budget(text))"
    }
}
