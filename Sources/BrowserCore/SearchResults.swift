import Foundation

/// Un résultat de recherche tel que le moteur le donne.
public struct SearchHit: Equatable, Sendable {
    public var title: String
    public var url: String
    public var snippet: String
    public init(title: String, url: String, snippet: String) { self.title = title; self.url = url; self.snippet = snippet }
}

/// Le tri fait par l'application avant que le modèle voie quoi que ce soit : annonces et doublons écartés, résultats classés par lien avec la question,
/// sources connues un peu favorisées, et un nombre de résultats proportionné à la question. Du code classique : aucun appel au modèle.
public enum SearchResultFilter {
    /// Combien de résultats montrer : une question courte en demande peu, une comparaison davantage.
    public static func limit(forQuery query: String) -> Int {
        let words = AIRouter.fold(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return AIRouter.isComplex(words: words) ? 5 : (words.count <= 3 ? 3 : 4)
    }

    public static func select(_ hits: [SearchHit], query: String, limit: Int? = nil, now: Date = Date()) -> [SearchHit] {
        let wanted = limit ?? Self.limit(forQuery: query)
        let terms = Self.terms(query)
        let year = Calendar.current.component(.year, from: now)
        let fresh = AIRouter.freshWords.contains { AIRouter.fold(query).contains($0) }
        var seen = Set<String>()
        var scored: [(hit: SearchHit, score: Double, index: Int, title: String)] = []
        for (index, hit) in hits.enumerated() {
            guard let key = canonical(hit.url), !isAdvert(hit.url), seen.insert(key).inserted else { continue }
            let title = AIRouter.fold(hit.title).filter { $0.isLetter || $0.isNumber }
            guard !title.isEmpty || !hit.snippet.isEmpty else { continue }
            var score = Double(overlap(terms, in: hit.title)) * 2 + Double(overlap(terms, in: hit.snippet)) + Double(overlap(terms, in: hit.url)) * 0.5
            score += trust(host: URL(string: hit.url)?.host ?? "")
            if fresh, hit.snippet.contains(String(year)) || hit.title.contains(String(year)) { score += 1 }
            score -= Double(index) * 0.15                                  // le moteur a déjà un avis : on le garde comme départage
            scored.append((hit, score, index, title))
        }
        // Deux résultats au même titre disent la même chose : on garde le mieux classé des deux.
        var bestForTitle: [String: Int] = [:]
        for (i, entry) in scored.enumerated() where !entry.title.isEmpty {
            if let j = bestForTitle[entry.title], scored[j].score >= entry.score { continue }
            bestForTitle[entry.title] = i
        }
        scored = scored.enumerated().filter { $0.element.title.isEmpty || bestForTitle[$0.element.title] == $0.offset }.map(\.element)
        let ranked = scored.sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
        return ranked.prefix(max(1, wanted)).map(\.hit)
    }

    // MARK: Détails

    /// Adresse comparable : sans « www. », sans fragment, sans paramètres de suivi, sans barre finale.
    static func canonical(_ raw: String) -> String? {
        guard var parts = URLComponents(string: raw), let host = parts.host?.lowercased(), parts.scheme == "http" || parts.scheme == "https" else { return nil }
        parts.fragment = nil
        parts.queryItems = parts.queryItems?.filter { item in !(item.name.hasPrefix("utm_") || ["fbclid", "gclid", "ref", "source", "cmpid"].contains(item.name)) }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        var path = parts.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) + (path == "/" ? "" : path) + (parts.query.map { "?" + $0 } ?? "")
    }

    /// Les annonces que le moteur glisse parmi les résultats passent par ses propres adresses de redirection.
    static func isAdvert(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let host = url.host?.lowercased() else { return true }
        return (host.hasSuffix("duckduckgo.com") && (url.path.hasPrefix("/y.js") || url.query?.contains("ad_provider") == true))
            || host.hasSuffix("googleadservices.com") || host.hasSuffix("doubleclick.net") || url.path.contains("/aclk")
    }

    static let stopwords: Set<String> = ["le", "la", "les", "un", "une", "des", "de", "du", "d", "l", "et", "ou", "a", "au", "aux", "en", "dans", "sur", "pour", "par", "avec", "que", "qui", "quoi",
                                         "est", "sont", "quel", "quelle", "quels", "quelles", "ce", "cet", "cette", "ces", "il", "elle", "y", "ne", "pas", "se", "sa", "son", "ses", "mon", "ma",
                                         "the", "of", "and", "to", "in", "is", "what", "how", "cherche", "recherche", "trouve", "web", "internet", "donne", "moi", "peux", "tu", "s", "il y a"]

    static func terms(_ text: String) -> [String] {
        AIRouter.fold(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 && !stopwords.contains($0) }
    }

    static func overlap(_ terms: [String], in text: String) -> Int {
        let folded = AIRouter.fold(text)
        return Set(terms).filter { folded.contains($0) }.count
    }

    /// Sources dont le contenu est en général vérifié ou officiel : un léger avantage, jamais de quoi écraser la pertinence.
    static func trust(host rawHost: String) -> Double {
        let host = rawHost.lowercased()
        let known = ["wikipedia.org", "gouv.fr", ".gov", ".edu", "europa.eu", "service-public.fr", "legifrance.gouv.fr", "bbc.com", "bbc.co.uk", "reuters.com", "lemonde.fr", "francetvinfo.fr",
                     "nature.com", "who.int", "developer.mozilla.org", "docs.", "meteofrance.com", "apple.com", "github.com"]
        let weak = ["pinterest.", "quora.com", "facebook.com", "instagram.com", "tiktok.com", "ebay.", "aliexpress.", "temu."]
        if known.contains(where: { host.contains($0) }) { return 0.8 }
        if weak.contains(where: { host.contains($0) }) { return -0.8 }
        return 0
    }

    /// Ce que lit le modèle : numéro, titre, adresse, extrait court.
    public static func format(_ hits: [SearchHit], snippetLimit: Int = 200) -> (text: String, sources: [String]) {
        var lines: [String] = [], sources: [String] = []
        for (i, hit) in hits.enumerated() {
            let snippet = hit.snippet.count > snippetLimit ? String(hit.snippet.prefix(snippetLimit)) + "…" : hit.snippet
            lines.append("\(i + 1). \(hit.title)\n   \(hit.url)\n   \(snippet)")
            if i < 3 { sources.append(hit.url) }
        }
        return (lines.joined(separator: "\n"), sources)
    }
}
