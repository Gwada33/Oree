import Foundation

/// Le passage que la personne vient de sélectionner : quand Luciole propose ses gestes, ce qu'on lui envoie, et le lien qui y ramène.
public enum SelectionPassage {
    /// Au moins trois mots, et pas un pavé entier (une sélection de toute la page n'est pas un passage).
    public static func isWorthOffering(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.count >= 3 && text.count <= 3000
    }

    /// Le passage, borné pour le modèle : les 1 500 premiers caractères, coupés à un mot.
    public static func excerpt(_ text: String, limit: Int = 1500) -> String {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard clean.count > limit else { return clean }
        let cut = String(clean.prefix(limit))
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? cut) + "…"
    }

    /// `page#:~:text=début,fin` : WebKit amène à ce passage et le surligne (fragment de texte). Les adresses déjà munies d'un fragment le gardent.
    public static func linkURL(page: URL, passage: String) -> URL {
        let words = passage.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 1, page.fragment == nil else { return page }
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&,-:~=+#%"))
        func encode(_ list: ArraySlice<String>) -> String { list.joined(separator: " ").addingPercentEncoding(withAllowedCharacters: allowed)?.replacingOccurrences(of: "-", with: "%2D") ?? "" }
        let directive = words.count <= 8 ? encode(words[...]) : encode(words.prefix(4)) + "," + encode(words.suffix(4))
        var components = URLComponents(url: page, resolvingAgainstBaseURL: false)
        components?.percentEncodedFragment = ":~:text=" + directive
        return components?.url ?? page
    }

    /// Les trois gestes de l'éventail et leur touche.
    public enum Gesture: String, CaseIterable, Sendable {
        case explain, translate, keep
        public var key: Character { switch self { case .explain: "e"; case .translate: "t"; case .keep: "g" } }
        public var title: String { switch self { case .explain: "Expliquer"; case .translate: "Traduire"; case .keep: "Garder" } }
        public var symbol: String { switch self { case .explain: "lightbulb"; case .translate: "character.bubble"; case .keep: "bookmark" } }
        /// La demande envoyée à Luciole (le passage y est une donnée, entourée de balises, jamais une consigne).
        public func prompt(for passage: String) -> String? {
            switch self {
            case .explain: "Explique simplement ce passage de la page :\n<page>\(excerpt(passage))</page>"
            case .translate: "Traduis en français ce passage, sans commentaire :\n<page>\(excerpt(passage))</page>"
            case .keep: nil
            }
        }
        public static func gesture(forKey key: Character) -> Gesture? { allCases.first { $0.key == Character(key.lowercased()) } }
    }
}

public extension LucioleGeometry {
    /// Le fil de lumière : de la bordure de la bulle la plus proche à la bordure du passage la plus proche, avec un point de contrôle qui le courbe.
    static func thread(from bubble: CGRect, to anchor: CGRect) -> (start: CGPoint, end: CGPoint, control: CGPoint) {
        let start: CGPoint, end: CGPoint
        if bubble.minX >= anchor.maxX { start = CGPoint(x: bubble.minX, y: min(max(anchor.midY, bubble.minY + 24), bubble.maxY - 24)); end = CGPoint(x: anchor.maxX, y: anchor.midY) }
        else if bubble.maxX <= anchor.minX { start = CGPoint(x: bubble.maxX, y: min(max(anchor.midY, bubble.minY + 24), bubble.maxY - 24)); end = CGPoint(x: anchor.minX, y: anchor.midY) }
        else if bubble.minY >= anchor.maxY { start = CGPoint(x: bubble.midX, y: bubble.minY); end = CGPoint(x: min(max(bubble.midX, anchor.minX), anchor.maxX), y: anchor.maxY) }
        else { start = CGPoint(x: bubble.midX, y: bubble.maxY); end = CGPoint(x: min(max(bubble.midX, anchor.minX), anchor.maxX), y: anchor.minY) }
        let horizontal = abs(start.x - end.x) >= abs(start.y - end.y)
        let control = horizontal ? CGPoint(x: (start.x + end.x) / 2, y: start.y) : CGPoint(x: start.x, y: (start.y + end.y) / 2)
        return (start, end, control)
    }

    /// La zone à ne pas cacher : toute la sélection si elle est courte, sinon sa dernière ligne (une sélection de vingt lignes ne se contourne pas).
    static func anchor(of rects: [CGRect], page: CGSize) -> CGRect? {
        guard let first = rects.first else { return nil }
        let union = rects.dropFirst().reduce(first) { $0.union($1) }
        return union.height <= page.height * 0.35 ? union : (rects.last ?? union)
    }
}
