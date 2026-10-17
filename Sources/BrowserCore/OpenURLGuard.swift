import Foundation

/// Un petit modèle peut inventer l'adresse à ouvrir (essai : « Ouvre https://www.wikipedia.org » → exemple.fr).
/// Si la demande contient des adresses, le modèle ne peut ouvrir qu'un site qu'elle nomme ou qu'une recherche a fait remonter.
public enum OpenURLGuard {
    public static func hosts(in text: String) -> Set<String> {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let found = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { $0.url }
        return Set(found.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }.compactMap { $0.host?.lowercased().replacingOccurrences(of: "www.", with: "") })
    }

    /// Un message pour le modèle si l'adresse n'est pas permise, sinon `nil`. Sans adresse dans la demande, rien n'est imposé.
    public static func problem(task: String, urlString: String, knownSources: [String]) -> String? {
        let wanted = hosts(in: task)
        guard !wanted.isEmpty else { return nil }
        let host = URL(string: urlString)?.host?.lowercased().replacingOccurrences(of: "www.", with: "") ?? ""
        if wanted.contains(host) { return nil }
        let known = Set(knownSources.compactMap { URL(string: $0)?.host?.lowercased().replacingOccurrences(of: "www.", with: "") })
        if known.contains(host) { return nil }
        return "Adresse refusée : la demande nomme \(wanted.sorted().joined(separator: ", ")). Ouvre exactement cette adresse, sans en inventer."
    }
}
