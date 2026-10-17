import Foundation

/// La mémoire ambiante : ce qu'Orée garde des pages lues pour que Luciole puisse les retrouver (« l'article sur WebKit lu mardi »). Tout reste sur ce Mac.
/// Ce fichier décide QUOI garder — jamais un onglet privé, jamais une page de connexion, de paiement ou de compte, jamais une page avec un champ de mot de passe.
public enum PageMemoryPolicy {
    public static let minimumCharacters = 400
    public static let maximumCharacters = 8000

    static let sensitivePathWords = ["login", "signin", "sign-in", "signup", "log-in", "auth", "password", "motdepasse", "mot-de-passe", "checkout", "payment", "paiement", "paiements",
                                     "billing", "account", "compte", "banque", "bank", "wallet", "oauth", "sso", "2fa", "otp"]
    static let sensitiveHostWords = ["bank", "banque", "paypal", "impots", "ameli", "secu", "mail.", "webmail", "accounts.", "login.", "auth.", "pay.", "secure.", "wallet"]

    public struct Page: Equatable, Sendable {
        public var url: URL; public var title: String; public var text: String
        public init(url: URL, title: String, text: String) { self.url = url; self.title = title; self.text = text }
    }

    /// La page à garder, ou nil si elle ne doit pas l'être. `exemptHosts` : les sites que la personne a exclus de la protection ou de la mémoire.
    public static func memorable(url: URL?, title: String, text: String, isPrivate: Bool, hasSecretField: Bool, exemptHosts: [String] = []) -> Page? {
        guard !isPrivate, !hasSecretField, let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased() else { return nil }
        if exemptHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return nil }
        if sensitiveHostWords.contains(where: host.contains) { return nil }
        let path = url.path.lowercased()
        if sensitivePathWords.contains(where: { path.contains($0) }) { return nil }
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard clean.count >= minimumCharacters else { return nil }
        var kept = url
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) { components.fragment = nil; components.query = nil; kept = components.url ?? url }      // ni paramètres ni jetons dans l'adresse gardée
        return Page(url: kept, title: String(title.prefix(200)), text: String(clean.prefix(maximumCharacters)))
    }

    /// Les mots de la question à chercher dans la mémoire : sans les mots vides, au plus six (la recherche exige tous les mots, donc peu).
    public static func keywords(from question: String) -> [String] {
        let stop: Set<String> = ["le", "la", "les", "un", "une", "des", "de", "du", "d", "l", "j", "ai", "lu", "vu", "que", "qui", "sur", "dans", "et", "ou", "en", "au", "aux", "ce", "cet", "cette",
                                 "mon", "ma", "mes", "article", "page", "site", "avais", "avait", "hier", "mardi", "lundi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche", "tout", "à", "heure",
                                 "retrouve", "retrouver", "souviens", "rappelle", "quel", "quelle", "quels", "est", "c", "était", "ça", "cela", "the", "a", "of"]
        let words = question.lowercased().folding(options: .diacriticInsensitive, locale: .current)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return Array(words.filter { $0.count > 2 && !stop.contains($0) }.prefix(6))
    }
}
