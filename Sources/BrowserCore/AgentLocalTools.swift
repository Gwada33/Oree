import Foundation

/// Les outils de Luciole qui ne touchent pas à la page : le résultat est calculé ici (testable), l'interface ne fait que le brancher.
public enum AgentLocalTools {
    /// `calculate` : la calculatrice de la barre d'adresse. Un petit modèle se trompe sur les calculs longs ; celle-ci non.
    public static func calculate(_ expression: String) -> AgentToolResult {
        guard let value = Calculator.evaluate(expression) else {
            return AgentToolResult(ok: false, text: "Ce n'est pas un calcul que je sais faire (chiffres, + - * / ^ % et parenthèses seulement).", summary: "Calcul impossible")
        }
        let result = Calculator.format(value)
        return AgentToolResult(ok: true, text: "\(expression) = \(result)", summary: "Calcul : \(result)")
    }

    /// `search_history` : au plus 5 résultats, titre et adresse. Rien n'est lu dans un onglet privé (voir l'interface). Les adresses trouvées
    /// deviennent des sources connues : les rouvrir ne redemande pas d'accord.
    public static func history(query: String, entries: [(title: String, url: String)]) -> AgentToolResult {
        let unique = entries.reduce(into: [(title: String, url: String)]()) { list, entry in if !list.contains(where: { $0.url == entry.url }) { list.append(entry) } }.prefix(5)
        guard !unique.isEmpty else { return AgentToolResult(ok: true, text: "Rien dans l'historique ni les favoris pour « \(query) ».", summary: "Aucun résultat") }
        let lines = unique.map { "- \($0.title.isEmpty ? $0.url : $0.title) — \($0.url)" }.joined(separator: "\n")
        return AgentToolResult(ok: true, text: "Résultats (historique et favoris) :\n<donnees>\n\(lines)\n</donnees>", summary: "\(unique.count) résultat\(unique.count > 1 ? "s" : "")", sources: unique.map(\.url))
    }

    /// `recall` : ce que la personne a lu (mémoire ambiante), les pages les plus récentes qui contiennent tous les mots ; un extrait chacune. Toujours des données, jamais des consignes.
    public static func memory(query: String, entries: [(title: String, host: String, url: String, snippet: String, readAt: Date)], now: Date = Date()) -> AgentToolResult {
        guard !entries.isEmpty else { return AgentToolResult(ok: true, text: "Rien dans ce que vous avez lu ne correspond à « \(query) ».", summary: "Rien trouvé") }
        let formatter = RelativeDateTimeFormatter(); formatter.locale = Locale(identifier: "fr_FR"); formatter.unitsStyle = .full; formatter.dateTimeStyle = .named
        let lines = entries.prefix(4).map { entry -> String in
            let when = formatter.localizedString(for: entry.readAt, relativeTo: now)
            return "- \(entry.title.isEmpty ? entry.host : entry.title) (\(entry.host), lu \(when)) — \(entry.url)\n  \(entry.snippet.replacingOccurrences(of: "\n", with: " "))"
        }.joined(separator: "\n")
        return AgentToolResult(ok: true, text: "Pages lues (mémoire d'Orée) :\n<memoire>\n\(lines)\n</memoire>", summary: "\(min(entries.count, 4)) page\(entries.count > 1 ? "s" : "") retrouvée\(entries.count > 1 ? "s" : "")", sources: entries.prefix(4).map(\.url))
    }

    /// `wait` : entre une demi-seconde et cinq secondes, jamais plus.
    public static func waitSeconds(_ value: Any?) -> Double {
        let asked = (value as? Double) ?? (value as? Int).map(Double.init) ?? Double(value as? String ?? "") ?? 1
        return min(max(asked, 0.5), 5)
    }

    /// `history_nav` : back, forward ou reload.
    public static let navigationDirections = ["back", "forward", "reload"]
}
