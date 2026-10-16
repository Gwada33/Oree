import Foundation

/// La carte de page que lit l'IA locale (« les yeux », étape 2 de Docs/ia.md). Le script de la page ne fait que relever les
/// éléments ; le tri par priorité, le budget et le format du contrat sont ici, en Swift pur, donc testés.
///
///     PAGE <url> "<titre>"
///     VISIBLE
///     @e1 link "Accueil" href=/
///     AUTRES +12
///     TEXTE
///     [h1] …
public struct PageMap: Equatable, Sendable {
    public struct Element: Equatable, Sendable, Codable {
        public var ref: Int
        public var role: String            // link, button, input, select, textarea, checkbox, radio…
        public var type: String?           // text, email, password…
        public var label: String
        public var visible: Bool
        public var inForm: Bool
        public var inNav: Bool
        public var attributes: [String: String]
        public init(ref: Int, role: String, type: String? = nil, label: String, visible: Bool, inForm: Bool = false, inNav: Bool = false, attributes: [String: String] = [:]) {
            self.ref = ref; self.role = role; self.type = type; self.label = label; self.visible = visible
            self.inForm = inForm; self.inNav = inNav; self.attributes = attributes
        }
    }
    public struct Block: Equatable, Sendable, Codable {
        public var tag: String
        public var text: String
        public init(tag: String, text: String) { self.tag = tag; self.text = text }
    }

    public var url: String
    public var title: String
    public var elements: [Element]
    public var blocks: [Block]
    public init(url: String, title: String, elements: [Element], blocks: [Block]) {
        self.url = url; self.title = title; self.elements = elements; self.blocks = blocks
    }

    public static let maxElements = 60
    public static let maxTextCharacters = 4000
    /// Un jeton ≈ 3,5 caractères en français : une estimation, pas une mesure du vrai tokenizer.
    public static func estimatedTokens(_ text: String) -> Int { Int((Double(text.utf8.count) / 3.5).rounded(.up)) }

    /// Types de champs dont la valeur ne sort jamais de la page (mots de passe, cartes, codes à usage unique).
    static let secretTypes: Set<String> = ["password"]
    static let secretHints = ["cc-", "one-time-code", "card", "cvc", "cvv", "iban", "password", "passwd", "mot de passe", "carte", "cryptogramme", "code de sécurité"]

    /// Un champ dont la valeur ne doit pas être lue : type secret, ou nom / autocomplete qui évoque une carte ou un mot de passe.
    public static func isSecret(type: String?, hints: [String]) -> Bool {
        if let type, secretTypes.contains(type.lowercased()) { return true }
        let joined = hints.joined(separator: " ").lowercased()
        return secretHints.contains { joined.contains($0) }
    }

    /// Ordre de priorité : visibles d'abord, puis les formulaires, puis la navigation, puis le reste ; à égalité, l'ordre de la page.
    func prioritized() -> [Element] {
        func rank(_ e: Element) -> Int { e.visible ? 0 : e.inForm ? 1 : e.inNav ? 2 : 3 }
        return elements.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    private static func clean(_ s: String, _ limit: Int) -> String {
        let flat = s.replacingOccurrences(of: "\"", with: "'").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    func line(_ e: Element) -> String {
        var out = "@e\(e.ref) \(e.role)"
        if let type = e.type, !type.isEmpty, type != e.role { out += "[\(type)]" }
        out += " \"\(Self.clean(e.label, 60))\""
        for key in e.attributes.keys.sorted() {
            let value = e.attributes[key] ?? ""
            out += value.isEmpty ? " \(key)" : " \(key)=\"\(Self.clean(value, 40))\""
        }
        return out
    }

    /// Le texte donné au modèle. Les éléments au-delà de `maxElements` sont comptés (« AUTRES +N »), pas listés.
    public func render(maxElements: Int = PageMap.maxElements, maxText: Int = PageMap.maxTextCharacters, focus: String? = nil) -> String {
        let ordered = prioritized()
        let shown = Array(ordered.prefix(maxElements))
        // On rend dans l'ordre de la page, pas dans l'ordre de priorité : c'est ce que lirait une personne.
        let keep = Set(shown.map(\.ref))
        let inPageOrder = elements.filter { keep.contains($0.ref) }
        var out = "PAGE \(url) \"\(Self.clean(title, 100))\"\nVISIBLE\n"
        out += inPageOrder.filter(\.visible).map(line).joined(separator: "\n")
        let hidden = inPageOrder.filter { !$0.visible }
        if !hidden.isEmpty { out += "\nHORS ÉCRAN\n" + hidden.map(line).joined(separator: "\n") }
        let others = ordered.count - shown.count
        if others > 0 { out += "\nAUTRES +\(others)" }
        out += "\nTEXTE\n"
        out += Self.renderText(blocks, budget: maxText, focus: focus)
        return out.trimmingCharacters(in: .newlines)
    }
}

// MARK: - Choix des passages

extension PageMap {
    /// Le texte de la page, dans la limite de `budget` caractères. Si tout tient, tout est donné. Sinon, avec une question (`focus`), on garde d'abord les titres
    /// (ils situent le reste) puis les passages qui parlent de la question, dans l'ordre de la page, en marquant ce qui est sauté ; sans rapport trouvé ou sans
    /// question, on garde le début de la page, comme avant.
    static func renderText(_ blocks: [Block], budget: Int, focus: String?) -> String {
        let cleaned = blocks.map { (tag: $0.tag, text: clean($0.text, 400)) }.filter { !$0.text.isEmpty }
        let total = cleaned.reduce(0) { $0 + $1.text.count }
        func line(_ block: (tag: String, text: String)) -> String { "[\(block.tag)] \(block.text)\n" }
        guard total > budget else { return cleaned.map(line).joined() }
        let terms = focus.map(SearchResultFilter.terms) ?? []
        var chosen = Set<Int>()
        var used = 0
        func take(_ index: Int) -> Bool {
            guard !chosen.contains(index), used + cleaned[index].text.count <= budget else { return false }
            chosen.insert(index); used += cleaned[index].text.count; return true
        }
        var matched = false
        if !terms.isEmpty {
            let scored = cleaned.enumerated().map { (index: $0.offset, score: SearchResultFilter.overlap(terms, in: $0.element.text)) }.filter { $0.score > 0 }
            if !scored.isEmpty {
                matched = true
                // Les titres d'abord, dans la limite d'un tiers du budget : ils disent de quoi parle chaque partie.
                for (index, block) in cleaned.enumerated() where block.tag.lowercased().hasPrefix("h") && used + block.text.count <= budget / 3 { _ = take(index) }
                for entry in scored.sorted(by: { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }) { _ = take(entry.index) }
                // Le premier passage (l'introduction) donne le sujet : s'il reste de la place, il reste.
                if !cleaned.isEmpty { _ = take(0) }
            }
        }
        if !matched { for index in cleaned.indices { if !take(index) { break } } }
        var out = "", skipped = false
        for (index, block) in cleaned.enumerated() {
            if chosen.contains(index) { if skipped { out += "[…]\n"; skipped = false }; out += line(block) } else { skipped = true }
        }
        return skipped ? out + "[…]\n" : out
    }
}

// MARK: - Lecture de ce que renvoie le script de la page

extension PageMap {
    private struct Raw: Decodable {
        struct Item: Decodable {
            var ref: Int, role: String, type: String?, label: String, visible: Bool, inForm: Bool, inNav: Bool
            var attributes: [String: String]?
            var hints: [String]?
        }
        var url: String, title: String
        var elements: [Item], blocks: [Block]
    }

    /// Décode la réponse du script. La valeur d'un champ secret est retirée ICI, avant tout autre traitement : c'est la seule porte de sortie.
    public static func decode(_ data: Data) -> PageMap? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        let elements = raw.elements.map { item -> Element in
            var attributes = item.attributes ?? [:]
            if isSecret(type: item.type, hints: item.hints ?? []) { attributes["value"] = nil; attributes["secret"] = "" }
            return Element(ref: item.ref, role: item.role, type: item.type, label: item.label, visible: item.visible,
                           inForm: item.inForm, inNav: item.inNav, attributes: attributes)
        }
        return PageMap(url: raw.url, title: raw.title, elements: elements, blocks: raw.blocks)
    }
}
