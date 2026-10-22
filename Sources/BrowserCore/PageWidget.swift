import Foundation

/// Un « widget » : une petite valeur lue sur une page d'un site (messages non lus, prochain rendez-vous…) et montrée dans la barre latérale d'Orée.
/// Il ne fait que LIRE : une source est un motif sur le titre de l'onglet ou un sélecteur CSS, jamais du script. Les widgets que l'IA propose passent par `WidgetPolicy.validated` avant toute exécution.
public struct PageWidget: Codable, Equatable, Sendable, Identifiable {
    public enum Source: Codable, Equatable, Sendable {
        /// Premier groupe capturé de ce motif dans le titre de l'onglet (Gmail : « Boîte de réception (3) »).
        case titleCount(pattern: String)
        /// Nombre d'éléments qui correspondent au sélecteur.
        case count(selector: String)
        /// Texte du premier élément qui correspond au sélecteur.
        case text(selector: String)
    }

    public var id: String
    public var host: String
    public var title: String
    /// Nom d'un symbole SF autorisé (`WidgetPolicy.symbols`).
    public var symbol: String
    public var hue: OreeTokens.Hue
    public var source: Source
    public var enabled: Bool

    public init(id: String = UUID().uuidString, host: String, title: String, symbol: String, hue: OreeTokens.Hue, source: Source, enabled: Bool = true) {
        self.id = id; self.host = host; self.title = title; self.symbol = symbol; self.hue = hue; self.source = source; self.enabled = enabled
    }
}

public enum WidgetPolicy {
    /// Symboles que l'IA peut choisir : un choix fermé, donc jamais un nom inventé qui s'afficherait vide.
    public static let symbols: Set<String> = [
        "envelope", "envelope.badge", "calendar", "calendar.badge.clock", "bell", "bell.badge", "message", "bubble.left", "person.2", "cart", "bag",
        "shippingbox", "creditcard", "chart.line.uptrend.xyaxis", "chart.bar", "newspaper", "play.rectangle", "music.note", "book", "doc.text",
        "folder", "checklist", "clock", "timer", "mappin.and.ellipse", "airplane", "car", "house", "heart", "star", "flag", "tag", "gift", "film",
        "gamecontroller", "graduationcap", "briefcase", "banknote", "tray", "tray.full", "paperplane", "list.bullet", "bolt", "flame", "cloud",
        "sun.max", "figure.run", "fork.knife", "cup.and.saucer",
    ]
    public static let fallbackSymbol = "circle.grid.2x2"
    public static let maxWidgets = 12
    static let maxPatternLength = 80
    static let maxTitleLength = 24

    /// Le widget de Gmail : le nombre entre parenthèses du titre, fiable parce que Gmail le met lui-même dans le titre de l'onglet.
    public static let gmail = PageWidget(id: "builtin.gmail", host: "mail.google.com", title: "Gmail", symbol: "envelope", hue: .marine,
                                         source: .titleCount(pattern: #"\((\d+)\)"#))
    public static let builtIn: [PageWidget] = [gmail]

    /// Le widget tel qu'on peut l'exécuter, ou nil s'il n'est pas sûr : hôte normalisé, titre court, symbole connu, motif qui compile avec un groupe, sélecteurs ni trop larges ni dangereux.
    public static func validated(_ widget: PageWidget) -> PageWidget? {
        var w = widget
        guard let host = ProtectionPolicy.normalized(w.host), host.contains(".") else { return nil }
        w.host = host
        w.title = String(w.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTitleLength))
        guard !w.title.isEmpty else { return nil }
        if !symbols.contains(w.symbol) { w.symbol = fallbackSymbol }
        switch w.source {
        case .titleCount(let pattern):
            guard pattern.count <= maxPatternLength, let regex = try? NSRegularExpression(pattern: pattern), regex.numberOfCaptureGroups == 1 else { return nil }
        case .count(let selector):
            guard let clean = BoostPolicy.sanitize(selector: selector) else { return nil }
            w.source = .count(selector: clean)
        case .text(let selector):
            guard let clean = BoostPolicy.sanitize(selector: selector) else { return nil }
            w.source = .text(selector: clean)
        }
        return w
    }

    /// Premier groupe capturé de `pattern` dans `title`.
    public static func capture(in title: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: title) else { return nil }
        return String(title[range])
    }

    /// Ce qui s'affiche dans la pastille : espaces réduits, nombre plafonné à « 99+ », texte coupé à 14 caractères ; nil si rien à montrer.
    public static func display(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        if let n = Int(text) { return n > 99 ? "99+" : String(n) }
        return text.count > 14 ? String(text.prefix(13)) + "…" : text
    }

    /// Un widget de `host` vaut pour ce domaine et ses sous-domaines.
    public static func matches(pageHost: String?, widgetHost: String) -> Bool {
        guard let host = ProtectionPolicy.normalized(pageHost) else { return false }
        return host == widgetHost || host.hasSuffix("." + widgetHost)
    }
}
