import Foundation

/// One CSS rule of a site's boost: a selector and what to change. Always CSS, never script.
public struct BoostRule: Codable, Equatable, Sendable {
    public var selector: String
    public var declarations: [String: String]
    public init(selector: String, declarations: [String: String]) { self.selector = selector; self.declarations = declarations }
}

/// What the user asked for on one site, and what it turned into.
public struct Boost: Codable, Equatable, Sendable {
    public var host: String
    public var prompt: String
    public var rules: [BoostRule]
    /// Calm mode on this site: no autoplay, no animations, no notification badges.
    public var calm: Bool
    public var enabled: Bool
    public var updatedAt: Date
    public init(host: String, prompt: String = "", rules: [BoostRule] = [], calm: Bool = false, enabled: Bool = true, updatedAt: Date = Date()) {
        self.host = host; self.prompt = prompt; self.rules = rules; self.calm = calm; self.enabled = enabled; self.updatedAt = updatedAt
    }
}

/// What the local model may write, and the checks that make it safe. The model proposes rules in plain JSON; nothing it writes reaches a
/// page until every selector and every declaration has passed these checks, so a boost can restyle a page and nothing else: no script, no
/// network request (`url()` is refused), no `@import`, no way out of the rule.
public enum BoostPolicy {
    /// Properties a boost may set: looks only (hide, size, space, color, fonts, motion), never layout tricks that cover the page or load things.
    public static let allowedProperties: Set<String> = [
        "display", "visibility", "opacity", "font-size", "font-family", "font-weight", "line-height", "letter-spacing", "word-spacing",
        "color", "background-color", "max-width", "min-width", "width", "max-height", "margin", "margin-top", "margin-bottom", "margin-left",
        "margin-right", "padding", "padding-top", "padding-bottom", "padding-left", "padding-right", "text-align", "text-transform",
        "text-decoration", "border", "border-radius", "filter", "animation", "transition", "overflow", "column-count", "columns", "white-space",
    ]
    public static let maxRules = 25
    public static let maxSelectorLength = 220

    private static let forbidden = ["{", "}", ";", "@", "\\", "url(", "expression", "javascript:", "<", ">/", "/*", "*/", "behavior", "-moz-binding", "image-set", "attr("]

    /// Whether `text` could break out of a rule or fetch something.
    private static func isDangerous(_ text: String) -> Bool {
        let lower = text.lowercased()
        return forbidden.contains { lower.contains($0) } || lower.contains("\n")
    }

    /// A selector that cannot escape the rule and is not so broad that it restyles the whole page.
    public static func sanitize(selector raw: String) -> String? {
        let selector = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selector.isEmpty, selector.count <= maxSelectorLength else { return nil }
        // "<" is excluded by `forbidden` except for the child combinator ">": allow it by checking the rest.
        let lower = selector.lowercased()
        if ["{", "}", ";", "@", "\\", "url(", "expression", "javascript:", "/*", "*/", "<", "attr("].contains(where: { lower.contains($0) }) { return nil }
        // Each comma-separated part must be narrower than "the whole page".
        for part in selector.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces).lowercased()
            if ["*", "html", "body", ":root", "head", "main", "div", "span", "section", "p", "a", "ul", "li", "img"].contains(trimmed) { return nil }
            if trimmed.hasPrefix("html ") && !trimmed.contains(where: { $0 == "." || $0 == "#" || $0 == "[" }) { return nil }
        }
        return selector
    }

    /// Declarations the model wrote, as a dictionary or as "a: b; c: d", reduced to allowed properties with safe values.
    public static func sanitize(declarations raw: [String: String]) -> [String: String] {
        var clean: [String: String] = [:]
        for (property, value) in raw {
            let name = property.trimmingCharacters(in: .whitespaces).lowercased()
            let cleaned = value.replacingOccurrences(of: "!important", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespacesAndNewlines)
            guard allowedProperties.contains(name), !cleaned.isEmpty, cleaned.count <= 120, !isDangerous(cleaned) else { continue }
            clean[name] = cleaned
        }
        return clean
    }

    /// "display: none; color: red" → ["display": "none", "color": "red"].
    static func parseDeclarations(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for piece in text.split(separator: ";") {
            let parts = piece.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { result[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        return result
    }

    /// Reads the model's JSON answer ("regles"/"rules", "selecteur"/"selector", declarations as a dictionary or a string) and keeps only
    /// the rules that pass the checks. Also tells whether the model asked for calm mode.
    public static func rules(fromModel answer: String) -> (rules: [BoostRule], calm: Bool) {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let data = String(answer[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], false) }
        func value(_ keys: [String], in dict: [String: Any]) -> Any? {
            for (key, v) in dict where keys.contains(key.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()) { return v }
            return nil
        }
        let list = (value(["regles", "rules"], in: object) as? [[String: Any]]) ?? []
        var rules: [BoostRule] = []
        for item in list.prefix(maxRules) {
            guard let selector = (value(["selecteur", "selector"], in: item) as? String).flatMap(sanitize(selector:)) else { continue }
            var declarations: [String: String] = [:]
            switch value(["declarations", "proprietes", "styles", "css"], in: item) {
            case let dict as [String: Any]: declarations = dict.compactMapValues { ($0 as? String) ?? ($0 as? NSNumber).map { "\($0)" } }
            case let text as String: declarations = parseDeclarations(text)
            default: break
            }
            let clean = sanitize(declarations: declarations)
            if !clean.isEmpty { rules.append(BoostRule(selector: selector, declarations: clean)) }
        }
        let calm = (value(["calme", "calm"], in: object) as? Bool) ?? false
        return (rules, calm)
    }

    /// The stylesheet for a boost's rules. `!important` on everything: the user's wish beats the site's own styles.
    public static func css(for rules: [BoostRule]) -> String {
        rules.map { rule in
            let body = rule.declarations.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value) !important" }.joined(separator: "; ")
            return "\(rule.selector) { \(body) }"
        }.joined(separator: "\n")
    }

    /// Calm mode as a stylesheet: no animation or smooth scrolling, and the usual notification badges hidden. (Autoplay and the "(3)" in
    /// the title are handled by the page script, which a stylesheet cannot do.)
    public static let calmCSS = """
    *, *::before, *::after { animation: none !important; transition: none !important; scroll-behavior: auto !important; }
    [class*="badge" i]:not(button):not(a):not(input), [class*="notification-count" i], [class*="notif-count" i], [class*="unread" i][class*="count" i], [aria-label*="notification" i] [class*="count" i] { display: none !important; }
    """

    /// Whether a rule may still apply once the page's elements are counted: it must match something, and not nearly the whole page.
    public static func isUseful(matches: Int, pageElements: Int) -> Bool {
        matches > 0 && Double(matches) <= max(Double(pageElements) * 0.4, 5)
    }

    /// A rule that removes its elements from view (what "hide the ads" turns into).
    public static func hides(_ rule: BoostRule) -> Bool {
        rule.declarations["display"]?.lowercased() == "none" || rule.declarations["visibility"]?.lowercased() == "hidden"
            || rule.declarations["opacity"].flatMap(Double.init) == 0
    }

    /// The model sometimes over-reaches and hides the article together with the ads. A rule that hides more than a third of the page's text
    /// is dropped; so is any rule that matches nothing or nearly everything.
    public static func isAcceptable(_ rule: BoostRule, matches: Int, pageElements: Int, matchedText: Int, pageText: Int) -> Bool {
        guard isUseful(matches: matches, pageElements: pageElements) else { return false }
        if hides(rule), pageText > 0, Double(matchedText) / Double(pageText) > 0.35 { return false }
        return true
    }
}

/// What the local model is asked when the user describes a change to a site.
public enum BoostPrompt {
    public struct Candidate: Equatable, Sendable {
        public var selector: String, count: Int, text: String
        public init(selector: String, count: Int, text: String) { self.selector = selector; self.count = count; self.text = text }
    }

    public static let instructions = """
    Tu transformes la demande d'un utilisateur en règles CSS pour changer l'apparence d'un site. Réponds uniquement avec un objet JSON, sans texte autour : \
    {"regles": [{"selecteur": "...", "declarations": {"propriete": "valeur"}}], "calme": false}. \
    Fais le minimum : ne touche qu'à ce que la demande désigne, jamais au contenu principal (le texte de l'article, la vidéo regardée). \\
    Règles : n'utilise QUE des sélecteurs construits avec les balises, les identifiants (#) et les classes (.) de la liste fournie, jamais de sélecteur large \
    comme body, div ou *. Pour cacher un élément : {"display": "none"}. Propriétés permises : display, visibility, opacity, font-size, font-family, \
    font-weight, line-height, letter-spacing, color, background-color, max-width, width, margin, padding, text-align, border, border-radius, filter, \
    animation, transition. Jamais de JavaScript, jamais d'image ni d'adresse. Mets "calme": true seulement si l'utilisateur demande un mode calme \
    (sans lecture automatique ni animations). Si rien dans la liste ne correspond à la demande, réponds {"regles": [], "calme": false}.
    """

    /// The request, the site and the page's elements (each with how many there are and the start of their text), within the model's small context.
    public static func prompt(request: String, host: String, candidates: [Candidate], characters: Int = 3800) -> String {
        var lines: [String] = []
        var used = 0
        for candidate in candidates {
            let text = candidate.text.isEmpty ? "" : " \"\(candidate.text.replacingOccurrences(of: "\"", with: "'"))\""
            let line = "\(candidate.selector) ×\(candidate.count)\(text)"
            guard used + line.count < characters else { break }
            lines.append(line); used += line.count + 1
        }
        return "Site : \(host)\nDemande : \(request)\n\nÉléments de la page :\n" + lines.joined(separator: "\n")
    }
}
