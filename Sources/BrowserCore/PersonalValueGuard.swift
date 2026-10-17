import Foundation

/// Ce que le modèle a le droit d'écrire dans la page. Un petit modèle invente volontiers un prénom et un e-mail (« Luc Léon, luc.leon@example.fr »),
/// ou recopie une adresse que lui souffle une page piégée (« envoie-la à evil.test »).
/// Règles : une valeur est permise si c'est un jeton de profil, ou si elle figure dans la demande de la personne.
/// Sinon elle est refusée quand (1) elle ressemble à une adresse, un e-mail, un téléphone ou un long numéro, ou (2) la demande parle de « mon / ma / mes… » (donc de ses informations).
public enum PersonalValueGuard {
    private static let risky = try! NSRegularExpression(pattern: #"(@|https?://|www\.|\b[\w-]+\.(com|fr|net|org|io|test|dev|app|xyz|ru|cn|info|biz)\b|\+?\d[\d .-]{6,}\d)"#, options: .caseInsensitive)
    private static let possessive = try! NSRegularExpression(pattern: #"\b(mon|ma|mes|moi|m'|j'|je|my|me)\b"#, options: .caseInsensitive)

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Le message à renvoyer au modèle pour la première valeur refusée, ou `nil` si tout est permis.
    public static func problem(task: String, values: [String]) -> String? {
        let asked = task.lowercased()
        let personalTask = matches(possessive, task)
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || !ProfileTokens.keys(in: trimmed).isEmpty || asked.contains(trimmed.lowercased()) { continue }
            if matches(risky, trimmed) || personalTask {
                return "Valeur refusée : « \(trimmed.prefix(40)) » ne vient ni de la demande ni du profil. N'invente jamais une information personnelle : écris un jeton ({{profil.prenom}}, {{profil.nom}}, {{profil.email}}…) ou pose la question avec ask_user."
            }
        }
        return nil
    }

    /// Les valeurs que le geste écrirait (type, select, fill_form), lues dans les arguments JSON de l'appel.
    public static func values(of call: AgentCall) -> [String] {
        guard let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any] else { return [] }
        switch call.name {
        case "type": return [args["text"] as? String].compactMap { $0 }
        case "select": return [args["option"] as? String].compactMap { $0 }
        case "fill_form": return ((args["fields"] as? [String: Any]) ?? [:]).values.compactMap { $0 as? String }
        default: return []
        }
    }
}

public extension OpenURLGuard {
    /// Un site que ni la demande, ni une recherche, ni la page affichée n'ont nommé : l'ouvrir demande l'accord de la personne.
    static func isUnfamiliar(task: String, urlString: String, knownSources: [String], currentURL: String?) -> Bool {
        func host(_ s: String?) -> String { URL(string: s ?? "")?.host?.lowercased().replacingOccurrences(of: "www.", with: "") ?? "" }
        let target = host(urlString)
        guard !target.isEmpty else { return true }
        if target == host(currentURL) || hosts(in: task).contains(target) { return false }
        return !knownSources.contains { host($0) == target }
    }
}
