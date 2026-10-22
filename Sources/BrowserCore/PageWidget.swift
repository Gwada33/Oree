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

extension PageWidget {
    /// Ce que le widget lit, en une phrase, pour l'aperçu.
    public var sourceDescription: String {
        switch source {
        case .titleCount: "le nombre entre parenthèses du titre de l'onglet"
        case .count(let selector): "nombre d'éléments « \(selector) »"
        case .text(let selector): "texte de « \(selector) »"
        }
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

// MARK: - Création par le modèle local

extension WidgetPolicy {
    /// Le texte d'une page réduit à sa forme (a = lettre, 0 = chiffre) : le modèle voit « un nombre » ou « un mot », jamais le contenu d'un message ou d'un agenda.
    public static func shape(_ text: String, limit: Int = 40) -> String {
        let mapped = text.map { $0.isLetter ? "a" : ($0.isNumber ? "0" : String($0)) }.joined()
        let squeezed = mapped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(squeezed.prefix(limit))
    }

    /// Une valeur lue au moment de la création : le widget n'est proposé que si elle existe vraiment (un compteur à ≥ 1, un texte non vide, un nombre dans le titre).
    public static func isUsable(_ widget: PageWidget, value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return false }
        switch widget.source {
        case .titleCount: return true
        case .count: return (Int(value) ?? 0) >= 1
        case .text: return value.count <= 160
        }
    }
}

extension WidgetPolicy {
    /// Le nom, le symbole et la teinte d'un widget, déduits de la demande et du site : le petit modèle local choisit mal ces détails et bien se tromper sur un nom ne change rien à la valeur lue.
    public static func style(forRequest request: String, host: String) -> (title: String, symbol: String, hue: OreeTokens.Hue) {
        let lower = request.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let table: [(keys: [String], symbol: String)] = [
            (["message", "mail", "courrier", "non lu", "inbox"], "envelope"), (["rendez", "agenda", "calendrier", "reunion", "evenement"], "calendar"),
            (["notif", "alerte"], "bell"), (["panier", "commande", "colis", "livraison"], "shippingbox"), (["prix", "cours", "bourse", "solde", "compte"], "chart.line.uptrend.xyaxis"),
            (["match", "score"], "flag"), (["tache", "todo", "a faire"], "checklist"), (["lecture", "article", "livre"], "book"), (["musique", "titre en cours"], "music.note"),
        ]
        let symbol = table.first { $0.keys.contains { lower.contains($0) } }?.symbol ?? fallbackSymbol
        let hues = OreeTokens.Hue.allCases
        let hue = hues[Int(host.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value } % UInt32(hues.count))]
        // « le nombre de messages non lus » → « Messages non lus »
        var words = request.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        let skip: Set<String> = ["le", "la", "les", "l'", "mon", "ma", "mes", "un", "une", "nombre", "total", "de", "des", "du", "d'"]
        while let first = words.first, skip.contains(first.lowercased()) { words.removeFirst() }
        var title = ""
        for word in words { let next = title.isEmpty ? word : title + " " + word; if next.count > maxTitleLength { break }; title = next }
        if title.isEmpty { title = host }
        return (title.prefix(1).uppercased() + title.dropFirst(), symbol, hue)
    }
}

public enum WidgetPrompt {
    public struct Candidate: Equatable, Sendable {
        public var selector: String, count: Int, text: String
        /// Combien de ces éléments sont écrits en gras (les 40 premiers) : sur une liste mixte, le gras signale le non lu.
        public var bolds: Int
        public init(selector: String, count: Int, text: String, bolds: Int = 0) { self.selector = selector; self.count = count; self.text = text; self.bolds = bolds }
    }

    /// Le motif du nombre du titre (« Boîte (3) »), le seul que le modèle n'a pas à écrire : il dit seulement « le titre ».
    public static let titlePattern = #"\((\d+)\)"#
    static let maxChoices = 45

    public static var instructions: String {
        """
        Tu aides à choisir UNE petite valeur à suivre sur une page web, d'après la demande. La page est décrite par une liste numérotée d'éléments (« ×N » : combien il y en a, \
        puis leur texte masqué : a = une lettre, 0 = un chiffre ; « k en gras » : combien sont écrits en gras, ce qui signale du non lu ou du nouveau quand tous ne le sont pas). \
        Réponds uniquement avec un objet JSON. Pour un NOMBRE d'éléments (messages non lus, notifications…) : {"choix": 3, "type": "nombre"}. \
        Pour le TEXTE d'un élément (prochain rendez-vous, solde…) : {"choix": 3, "type": "texte"}. \
        Si la réponse est le nombre entre parenthèses du titre de l'onglet : {"type": "titre"}. \
        « choix » est le NUMÉRO d'une ligne de la liste, un seul. Pour un nombre, prends la ligne dont le « ×N » compte ce que la demande veut compter. Si rien ne correspond : {"type": "aucun"}.
        """
    }

    public static func prompt(request: String, host: String, title: String, candidates: [Candidate], characters: Int = 3400) -> String {
        var lines: [String] = []
        var used = 0
        for (index, candidate) in candidates.prefix(maxChoices).enumerated() {   // l'ordre est celui de `candidates` : le même sert à retrouver le numéro choisi
            let text = candidate.text.isEmpty ? "" : " \"\(WidgetPolicy.shape(candidate.text))\""
            let line = "\(index + 1). \(candidate.selector) ×\(candidate.count)\(text)\(candidate.bolds > 0 ? ", \(candidate.bolds) en gras" : "")"
            guard used + line.count < characters else { break }
            lines.append(line); used += line.count + 1
        }
        return "Site : \(host)\nDemande : \(request)\nTitre de l'onglet : \(WidgetPolicy.shape(title, limit: 80))\n\nÉléments de la page :\n" + lines.joined(separator: "\n")
    }

    /// Le widget que décrit la réponse du modèle, ou nil si elle est illisible, « aucun », ou refusée par `WidgetPolicy.validated`. Le modèle ne rédige aucun sélecteur : il désigne un numéro de la liste.
    public static func widget(fromModel answer: String, host: String, request: String, candidates: [Candidate]) -> PageWidget? {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let data = String(answer[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func value(_ keys: [String]) -> Any? {
            for (key, v) in object where keys.contains(key.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()) { return v }
            return nil
        }
        guard let kind = (value(["type"]) as? String)?.lowercased() else { return nil }
        let source: PageWidget.Source
        switch kind {
        case "titre", "title": source = .titleCount(pattern: titlePattern)
        case "nombre", "count", "texte", "text":
            let number = (value(["choix", "numero", "choice"]) as? NSNumber)?.intValue ?? (value(["choix", "numero", "choice"]) as? String).flatMap { Int($0) }
            guard let number, number >= 1, number <= min(candidates.count, maxChoices) else { return nil }
            let selector = candidates[number - 1].selector
            source = kind == "nombre" || kind == "count" ? .count(selector: selector) : .text(selector: selector)
        default: return nil
        }
        let style = WidgetPolicy.style(forRequest: request, host: host)
        return WidgetPolicy.validated(PageWidget(host: host, title: style.title, symbol: style.symbol, hue: style.hue, source: source))
    }
}
