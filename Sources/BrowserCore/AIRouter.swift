import Foundation

/// D'où Luciole tire sa réponse, choisi par des règles légères (aucun appel au modèle) avant le premier tour. La source la plus directe et la moins chère d'abord.
public enum AIRoute: String, Equatable, Sendable {
    case direct      // une connaissance générale suffit : ni page, ni recherche d'office
    case page        // la question porte sur la page ouverte : son contenu d'abord
    case web         // une information récente ou à vérifier : recherche ciblée
    case agent       // il faut agir dans la page (remplir, cliquer, ouvrir) : carte de la page et tous les outils
}

/// Ce que le routage décide pour la suite : ce qu'on met dans le contexte, ce que le modèle a le droit d'utiliser, combien il peut écrire.
public struct AIPlan: Equatable, Sendable {
    public var route: AIRoute
    public var includePage: Bool
    public var tools: [String]
    public var maxSearches: Int
    public var maxTokens: Int
    public var maxSteps: Int                 // les tours au plus : une question simple ne mérite pas quinze tentatives
    public var keepsConversation: Bool       // la question reprend-elle ce qui vient d'être dit ?
}

public enum AIRouter {
    /// Les outils, du plus petit au plus large. `read_page` n'est proposé que quand la carte de la page n'est PAS déjà dans le contexte (sinon c'est la même chose, payée deux fois).
    static let base = ["done", "ask_user"]

    public static func plan(question: String, pageReadable: Bool, hasConversation: Bool = false) -> AIPlan {
        let text = fold(question)
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let route = route(text: text, words: words, pageReadable: pageReadable)
        let follow = hasConversation && isFollowUp(text: text, words: words)
        switch route {
        case .direct:
            // Sans page. Une page à lire reste possible (read_page) et une recherche aussi, mais le modèle n'en reçoit ni le texte ni l'obligation.
            return AIPlan(route: .direct, includePage: false, tools: base + (pageReadable ? ["read_page"] : []) + ["search_web", "calculate", "search_history"], maxSearches: 1, maxTokens: 900, maxSteps: 4, keepsConversation: follow)
        case .page:
            return AIPlan(route: .page, includePage: true, tools: base + ["scroll", "search_web"], maxSearches: 1, maxTokens: 1100, maxSteps: 6, keepsConversation: follow)
        case .web:
            return AIPlan(route: .web, includePage: false, tools: base + ["search_web", "open_url"] + (pageReadable ? ["read_page"] : []), maxSearches: isComplex(words: words) ? 3 : 2, maxTokens: 1100, maxSteps: 8, keepsConversation: follow)
        case .agent:
            return AIPlan(route: .agent, includePage: true, tools: AgentParser.tools.filter { $0 != "read_page" }, maxSearches: 3, maxTokens: 800, maxSteps: 15, keepsConversation: true)
        }
    }

    /// Le modèle demande un outil qui agit sur la page alors que le routage n'en avait pas prévu (la question ne le laissait pas deviner) : on passe en mode action,
    /// avec la page. Le routage sert à économiser, jamais à empêcher.
    public static func escalated() -> AIPlan {
        AIPlan(route: .agent, includePage: true, tools: AgentParser.tools.filter { $0 != "read_page" }, maxSearches: 3, maxTokens: 800, maxSteps: 15, keepsConversation: true)
    }

    public static func route(text: String, words: [String], pageReadable: Bool) -> AIRoute {
        let phrase = " " + words.joined(separator: " ") + " "
        func has(_ list: [String]) -> Bool { list.contains { phrase.contains(" \($0) ") || ($0.contains(" ") && text.contains($0)) } }
        if has(actionWords) { return .agent }
        if has(searchRequests) { return .web }
        if pageReadable, has(pageWords) { return .page }
        if has(freshWords) || hasRecentYear(words) { return .web }
        return .direct
    }

    /// Une question qui reprend la précédente (« et à Madrid ? », « pourquoi ? ») : courte, ou avec un renvoi (« il », « celle-ci », « aussi »).
    public static func isFollowUp(text: String, words: [String]) -> Bool {
        if words.count <= 5 { return true }
        let phrase = " " + words.joined(separator: " ") + " "
        return followMarkers.contains { phrase.contains(" \($0) ") }
    }

    static func isComplex(words: [String]) -> Bool {
        words.count > 12 || !Set(words).isDisjoint(with: ["compare", "comparer", "difference", "differences", "versus", "vs", "meilleur", "meilleurs", "avis"])
    }

    // MARK: Mots (sans accent, en minuscules)

    static let actionWords = ["remplis", "remplir", "remplissez", "clique", "cliquer", "clique sur", "ouvre", "ouvrir", "va sur", "aller sur", "navigue", "connecte moi", "connecte-moi",
                              "inscris", "inscris moi", "renvoie", "renvoyer", "supprime", "supprimer", "efface", "effacer", "publie", "poste", "abonne", "reserve", "reserver", "achete", "acheter", "commande", "commander", "ajoute au panier", "envoie", "envoyer", "telecharge", "telecharger",
                              "coche", "selectionne", "saisis", "tape", "valide", "soumets", "postule", "scrolle", "defile", "defiler", "fais defiler", "descends", "fill", "click", "open"]
    static let searchRequests = ["cherche", "chercher", "recherche", "rechercher", "trouve", "trouver", "google", "sur le web", "sur internet", "en ligne", "search", "look up"]
    static let pageWords = ["page", "article", "site", "onglet", "texte", "document", "ici", "resume", "resumer", "resumez", "synthese", "points cles", "traduis", "traduire", "cette", "ce site", "celui ci", "celle ci", "ci dessus", "auteur", "titre", "paragraphe", "section"]
    static let freshWords = ["aujourd hui", "aujourd'hui", "demain", "hier", "cette semaine", "ce soir", "actuel", "actuelle", "actuellement", "dernier", "derniere", "derniers", "dernieres", "nouvelles", "recent", "recente", "recemment",
                             "nouveau", "nouvelle", "nouveautes", "actualite", "actualites", "news", "meteo", "cours", "prix", "tarif", "score", "resultat", "resultats", "classement", "horaires",
                             "meilleur", "meilleure", "meilleurs", "meilleures", "avis", "compare", "comparer", "comparatif", "versus", "vs", "ouvert", "stock", "disponible", "en ce moment", "maintenant", "qui a gagne", "sorti", "sortie", "today", "latest", "current", "weather", "price"]
    static let followMarkers = ["il", "elle", "ils", "elles", "ca", "cela", "celui", "celle", "ceux", "aussi", "meme", "autre", "autres", "plus", "moins", "encore", "pareil", "precedent", "precedente", "alors", "donc"]

    static func hasRecentYear(_ words: [String]) -> Bool {
        let year = Calendar.current.component(.year, from: Date())
        return words.contains { [String(year), String(year - 1), String(year + 1)].contains($0) }
    }

    /// Minuscules sans accents ni apostrophes typographiques : « Aujourd’hui » → « aujourd'hui ».
    public static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR")).replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
    }
}
