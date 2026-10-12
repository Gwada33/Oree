import Foundation

/// LM Studio : un serveur local (compatible OpenAI) qui prête les modèles que la personne a téléchargés dans l'application LM Studio. Rien ne quitte le Mac
/// tant que l'adresse reste « localhost ». Pur : adresses, liste des modèles, test de boucle locale ; le réseau est dans `CloudClient`.
public enum LMStudio {
    public static let defaultBase = URL(string: "http://localhost:1234/v1")!

    /// « localhost:1234 », « 192.168.1.5:1234/v1 », « http://localhost:1234 » → une adresse de base complète, qui finit par `/v1`. Vide : l'adresse d'origine.
    public static func normalizedBase(_ text: String) -> URL {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return defaultBase }
        if !raw.contains("://") { raw = "http://" + raw }
        while raw.hasSuffix("/") { raw.removeLast() }
        guard var components = URLComponents(string: raw), components.host != nil else { return defaultBase }
        if components.path.isEmpty { components.path = "/v1" }
        return components.url ?? defaultBase
    }

    public static func chatURL(base: URL) -> URL { base.appendingPathComponent("chat/completions") }
    public static func modelsURL(base: URL) -> URL { base.appendingPathComponent("models") }

    /// Les modèles de conversation du serveur (les modèles d'« embedding » ne répondent pas aux questions : écartés).
    public static func parseModels(_ data: Data) -> [String] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let list = object["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["id"] as? String }.filter { !$0.lowercased().contains("embed") }
    }

    /// Vrai pour localhost, 127.x et ::1 : le serveur est sur ce Mac. Sinon (un autre ordinateur du réseau), le panneau prévient que les pages lues y sont envoyées.
    public static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "::1" || host == "[::1]" || host.hasPrefix("127.")
    }

    /// Le modèle à utiliser : celui des réglages s'il est chargé, sinon le premier de la liste.
    public static func chooseModel(preferred: String, available: [String]) -> String? {
        if !preferred.isEmpty, available.isEmpty || available.contains(preferred) { return preferred }
        return available.first
    }
}
