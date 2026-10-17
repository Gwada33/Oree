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

    /// `wait` : entre une demi-seconde et cinq secondes, jamais plus.
    public static func waitSeconds(_ value: Any?) -> Double {
        let asked = (value as? Double) ?? (value as? Int).map(Double.init) ?? Double(value as? String ?? "") ?? 1
        return min(max(asked, 0.5), 5)
    }

    /// `history_nav` : back, forward ou reload.
    public static let navigationDirections = ["back", "forward", "reload"]
}
