import Foundation
import Testing
@testable import BrowserCore

@Suite("Tri des résultats de recherche")
struct SearchResultsTests {
    private func hit(_ title: String, _ url: String, _ snippet: String = "") -> SearchHit { SearchHit(title: title, url: url, snippet: snippet) }

    @Test("annonces, doublons d'adresse (www, fragment, suivi) et doublons de titre disparaissent")
    func dedupe() {
        let hits = [
            hit("Météo Lyon — Météo-France", "https://meteofrance.com/lyon", "Prévisions pour Lyon aujourd'hui"),
            hit("Annonce : voyages pas chers", "https://duckduckgo.com/y.js?ad_provider=bing&u=abc", "Réservez"),
            hit("Météo Lyon — Météo-France", "https://www.meteofrance.com/lyon/?utm_source=x#haut", "Prévisions pour Lyon aujourd'hui"),
            hit("Météo Lyon", "https://meteofrance.com/lyon/", "Prévisions"),
            hit("Prévisions Lyon 7 jours", "https://autre.example/lyon", "Météo à Lyon sur 7 jours"),
        ]
        let kept = SearchResultFilter.select(hits, query: "météo Lyon aujourd'hui", limit: 5)
        #expect(kept.count == 2)
        #expect(kept.contains { $0.url == "https://meteofrance.com/lyon" })
        #expect(!kept.contains { $0.url.contains("y.js") })
    }

    @Test("le plus pertinent passe devant, même s'il vient après")
    func relevance() {
        let hits = [
            hit("Accueil du site", "https://a.example/", "Bienvenue sur notre site de recettes"),
            hit("Population de Porto en 2025", "https://b.example/porto", "Porto compte 273 476 habitants"),
            hit("Les plus belles villes", "https://c.example/villes", "Un tour du monde"),
        ]
        let kept = SearchResultFilter.select(hits, query: "population de Porto", limit: 2)
        #expect(kept.first?.url == "https://b.example/porto")
        #expect(kept.count == 2)
    }

    @Test("sources connues un peu favorisées, sources faibles un peu défavorisées, jamais au détriment de la pertinence")
    func trust() {
        let hits = [
            hit("Porto", "https://pinterest.fr/porto", "Porto"),
            hit("Porto", "https://fr.wikipedia.org/wiki/Porto", "Porto"),
        ]
        // Même pertinence : on garde la source connue (les titres sont identiques : un seul reste).
        #expect(SearchResultFilter.select(hits, query: "Porto", limit: 3).count == 1)
        #expect(SearchResultFilter.select(hits, query: "Porto", limit: 3).first?.url.contains("wikipedia") == true)
        let off = [hit("Sujet sans rapport", "https://fr.wikipedia.org/wiki/Autre", "Autre chose"), hit("Voyage à Porto en famille", "https://blog.example/porto", "Notre séjour à Porto")]
        #expect(SearchResultFilter.select(off, query: "voyage Porto famille", limit: 1).first?.url == "https://blog.example/porto")
    }

    @Test("la limite suit la question, et il en reste toujours au moins un")
    func limits() {
        #expect(SearchResultFilter.limit(forQuery: "météo Lyon") == 3)
        #expect(SearchResultFilter.limit(forQuery: "quelle est la population de Porto") == 4)
        #expect(SearchResultFilter.limit(forQuery: "compare les meilleurs casques à réduction de bruit") == 5)
        #expect(SearchResultFilter.select([hit("A", "https://a.example/", "x")], query: "zzz", limit: 0).count == 1)
        #expect(SearchResultFilter.select([], query: "x").isEmpty)
    }

    @Test("des adresses qui ne sont pas du web sont écartées")
    func schemes() {
        let kept = SearchResultFilter.select([hit("Fichier", "file:///etc/passwd", "x"), hit("Script", "javascript:alert(1)", "x"), hit("Page", "https://ok.example/", "x")], query: "page", limit: 5)
        #expect(kept.map(\.url) == ["https://ok.example/"])
    }

    @Test("mise en forme : numéro, titre, adresse, extrait coupé ; trois sources au plus")
    func format() {
        let long = String(repeating: "a", count: 300)
        let out = SearchResultFilter.format((1...5).map { hit("T\($0)", "https://x.example/\($0)", long) })
        #expect(out.sources.count == 3)
        #expect(out.text.contains("1. T1\n   https://x.example/1\n   "))
        #expect(out.text.contains("…"))
    }
}

@Suite("Cache à durée de vie")
struct TTLCacheTests {
    @Test("frais puis périmé")
    func expiry() {
        let cache = TTLCache<String>()
        let t0 = Date(timeIntervalSince1970: 1000)
        cache.set("v", for: "k", ttl: 60, now: t0)
        #expect(cache.value(for: "k", now: t0.addingTimeInterval(59)) == "v")
        #expect(cache.value(for: "k", now: t0.addingTimeInterval(61)) == nil)
        #expect(cache.count == 0)                      // une valeur périmée est retirée à la lecture
    }

    @Test("invalidation par préfixe, et plafond de taille")
    func invalidation() {
        let cache = TTLCache<Int>(capacity: 3)
        let t0 = Date(timeIntervalSince1970: 1000)
        for i in 0..<5 { cache.set(i, for: "search:\(i)", ttl: 100 + Double(i), now: t0) }
        #expect(cache.count == 3)
        #expect(cache.value(for: "search:4", now: t0) == 4)       // les plus récentes restent
        cache.set(9, for: "page:a", ttl: 100, now: t0)
        cache.remove(prefix: "search:")
        #expect(cache.count == 1 && cache.value(for: "page:a", now: t0) == 9)
        cache.removeAll()
        #expect(cache.count == 0)
    }
}
