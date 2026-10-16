import Foundation
import Testing
import CryptoKit
@testable import BrowserCore

@Suite("Journal : schéma et confidentialité")
struct JournalSchemaTests {
    private func event(_ name: String, _ d: [String: JournalValue], t: Double = 1_800_000_000.1234) -> JournalEvent { JournalEvent(t: t, e: name, d: d) }

    @Test("un événement inconnu n'est jamais écrit")
    func unknown() {
        #expect(JournalSchema.validate(event("page.content", ["text": .string("secret")])) == nil)
        #expect(JournalSchema.validate(event("", [:])) == nil)
    }

    @Test("un champ inconnu est jeté, un nombre est ramené dans ses bornes, l'instant est arrondi à la milliseconde")
    func clamps() throws {
        let clean = try #require(JournalSchema.validate(event("tab.select", ["tab": .string("a1b2"), "via": .string("click"), "dwell": .int(99_999_999), "url": .string("https://x.example/secret"), "title": .string("Ma banque")])))
        #expect(clean.d["url"] == nil && clean.d["title"] == nil)
        #expect(clean.d["dwell"] == .int(3_600_000))
        #expect(clean.d["tab"] == .string("a1b2") && clean.d["via"] == .string("click"))
        #expect(clean.t == 1_800_000_000.123)
        let negative = try #require(JournalSchema.validate(event("ptr.window", ["tab": .string("a1b2"), "dist": .int(-5), "dx": .int(-5_000_000)])))
        #expect(negative.d["dist"] == .int(0) && negative.d["dx"] == .int(-100_000))
    }

    @Test("un texte hors liste est refusé : ni adresse ni titre ne peuvent entrer par un champ « choix »")
    func closedLists() throws {
        let clean = try #require(JournalSchema.validate(event("tab.open", ["tab": .string("a1b2"), "how": .string("https://evil.example/?q=mot-de-passe"), "n": .int(3)])))
        #expect(clean.d["how"] == nil && clean.d["n"] == .int(3))
        #expect(JournalSchema.validate(event("tab.select", ["tab": .string("une adresse https://x.example"), "dwell": .int(1)]))?.d["tab"] == nil)
        // Une empreinte, c'est 4 ou 16 caractères hexadécimaux en minuscules, rien d'autre.
        #expect(JournalSchema.validate(event("nav.done", ["site": .string("ABCDEF0123456789"), "ms": .int(5)]))?.d["site"] == nil)
        #expect(JournalSchema.validate(event("nav.done", ["site": .string("abcdef0123456789"), "ms": .int(5)]))?.d["site"] == .string("abcdef0123456789"))
        #expect(JournalSchema.validate(event("nav.done", ["site": .string("www.banque.fr"), "ms": .int(5)]))?.d["site"] == nil)
    }

    @Test("la version de l'app : chiffres, points, tirets seulement")
    func version() {
        #expect(JournalSchema.validate(event("session.start", ["ver": .string("1.1.0")]))?.d["ver"] == .string("1.1.0"))
        #expect(JournalSchema.validate(event("session.start", ["ver": .string("1.1<script>")]))?.d["ver"] == nil)
    }

    @Test("des nombres flottants infinis ou des types qui ne vont pas sont écartés")
    func wrongTypes() {
        #expect(JournalSchema.validate(event("tab.close", ["life": .double(.infinity), "fg": .string("12"), "n": .bool(true)]))?.d.isEmpty == true)
    }

    @Test("chaque événement prévu a des champs bien formés (le schéma lui-même est cohérent)")
    func schemaIsSane() {
        #expect(JournalSchema.events.count >= 30)
        for (name, fields) in JournalSchema.events {
            #expect(name.contains(".") || name == "media", "« \(name) » : nom attendu en « domaine.action »")
            #expect(!fields.isEmpty)
            // Aucun champ ne porte un nom qui évoque un contenu.
            for key in fields.keys { #expect(!["url", "title", "text", "href", "host", "query", "value", "key", "name"].contains(key) || (name == "ui.panel" && key == "name"), "« \(name).\(key) » ressemble à un contenu") }
        }
    }
}

@Suite("Journal : empreintes de sites et classes")
struct JournalPrivacyTests {
    private let key = SiteHash.key(from: SymmetricKey(data: Data(repeating: 9, count: 32)))

    @Test("le domaine de site : sous-domaines retirés, suffixes à deux niveaux gardés, adresses IP entières")
    func domains() {
        #expect(SiteHash.registrableDomain("fr.Wikipedia.org") == "wikipedia.org")
        #expect(SiteHash.registrableDomain("www.bbc.co.uk") == "bbc.co.uk")
        #expect(SiteHash.registrableDomain("impots.gouv.fr") == "impots.gouv.fr")
        #expect(SiteHash.registrableDomain("localhost") == "localhost")
        #expect(SiteHash.registrableDomain("192.168.1.20") == "192.168.1.20")
        #expect(SiteHash.registrableDomain("example.com.") == "example.com")
    }

    @Test("même site → même empreinte ; autre site, autre clé → autre empreinte ; 16 caractères hexadécimaux")
    func hashes() {
        let a = SiteHash.hash(host: "www.example.com", key: key), b = SiteHash.hash(host: "blog.example.com", key: key), c = SiteHash.hash(host: "other.org", key: key)
        #expect(a == b && a != c && a.count == 16 && a.allSatisfy(\.isHexDigit))
        let other = SiteHash.key(from: SymmetricKey(data: Data(repeating: 1, count: 32)))
        #expect(SiteHash.hash(host: "example.com", key: other) != a)
        #expect(!a.contains("example"))
    }

    @Test("identifiants d'onglet : 4 caractères hexadécimaux")
    func tabIDs() {
        for _ in 0..<50 { let id = SiteHash.randomTabID(); #expect(id.count == 4 && id.allSatisfy(\.isHexDigit)) }
    }

    @Test("classes de tailles et cases de grille")
    func buckets() {
        #expect(JournalBucket.log2(0) == 0 && JournalBucket.log2(1) == 1 && JournalBucket.log2(3) == 2 && JournalBucket.log2(4) == 3 && JournalBucket.log2(1_000_000_000) == 12)
        #expect(JournalBucket.cell(0, of: 1000) == 0 && JournalBucket.cell(999, of: 1000) == 9 && JournalBucket.cell(1500, of: 1000) == 9 && JournalBucket.cell(-5, of: 1000) == 0 && JournalBucket.cell(5, of: 0) == 0)
        #expect(JournalBucket.hundreds(1280) == 13)
    }

    @Test("qui peut être observé : pages web ordinaires d'onglets ordinaires")
    func policy() {
        let web = URL(string: "https://example.com/a")
        #expect(JournalPolicy.allowsPage(url: web, isPrivate: false))
        #expect(!JournalPolicy.allowsPage(url: web, isPrivate: true))
        #expect(!JournalPolicy.allowsPage(url: URL(string: "oree://home/"), isPrivate: false))
        #expect(!JournalPolicy.allowsPage(url: URL(string: "file:///etc/hosts"), isPrivate: false))
        #expect(!JournalPolicy.allowsPage(url: nil, isPrivate: false))
    }
}

@Suite("Journal : messages venus d'une page")
struct JournalIngestTests {
    private let key = SiteHash.key(from: SymmetricKey(data: Data(repeating: 3, count: 32)))
    private func ingest(_ body: Any, pageSite: String = "0123456789abcdef") -> [JournalEvent] {
        JournalIngest.events(from: body, tab: "ab12", pageSite: pageSite, now: 1_800_000_000) { SiteHash.hash(host: $0, key: key) }
    }

    @Test("un lien survolé : le nom d'hôte devient une empreinte et ne reste nulle part")
    func link() throws {
        let events = ingest(["ev": [["e": "link.hover", "d": ["host": "news.example.org", "dwell": 640, "clicked": true, "gx": 3, "gy": 1, "y": 12, "kind": "content"]]]])
        let e = try #require(events.first)
        let json = String(decoding: try JSONEncoder().encode(e), as: UTF8.self)
        #expect(!json.contains("example") && !json.contains("news"))
        #expect(e.d["site"] == .string(SiteHash.hash(host: "example.org", key: key)) && e.d["same"] == .bool(false) && e.d["external"] == .bool(true))
        #expect(e.d["tab"] == .string("ab12") && e.d["dwell"] == .int(640) && e.d["clicked"] == .bool(true))
    }

    @Test("un lien du même site est reconnu comme tel")
    func sameSite() throws {
        let pageSite = SiteHash.hash(host: "example.org", key: key)
        let e = try #require(ingest(["ev": [["e": "link.click", "d": ["host": "www.example.org", "dwell": 200, "via": "mouse"]]]], pageSite: pageSite).first)
        #expect(e.d["same"] == .bool(true) && e.d["external"] == .bool(false))
    }

    @Test("une page ne peut écrire que les événements prévus pour elle")
    func onlyAllowedEvents() {
        let body: [String: Any] = ["ev": [["e": "tab.close", "d": ["tab": "ab12", "life": 5]], ["e": "session.start", "d": ["cold": 1]], ["e": "ai.task", "d": ["req": 3]], ["e": "ptr.window", "d": ["dist": 50]]]]
        #expect(ingest(body).map(\.e) == ["ptr.window"])
    }

    @Test("un texte glissé dans un champ, ou un faux onglet, est écarté ou remplacé")
    func spoofing() throws {
        let e = try #require(ingest(["ev": [["e": "ptr.click", "d": ["tag": "<img src=x onerror=1>", "gx": 3, "gy": 4, "since": 20, "tab": "ffff", "url": "https://secret.example/"]]]]).first)
        #expect(e.d["tag"] == nil && e.d["url"] == nil)
        #expect(e.d["tab"] == .string("ab12"))                   // l'onglet est celui que l'app connaît, pas celui que la page prétend
    }

    @Test("les événements de page prennent le site de la page, pas celui que la page annonce")
    func pageSite() throws {
        let e = try #require(ingest(["ev": [["e": "page.shape", "d": ["site": "deadbeefdeadbeef", "links": 12, "password": false, "kind": "article"]]]]).first)
        #expect(e.d["site"] == .string("0123456789abcdef"))
    }

    @Test("un message énorme est tronqué ; un message illisible donne rien")
    func limits() {
        let many = (0..<500).map { _ in ["e": "ptr.window", "d": ["dist": 1]] as [String: Any] }
        #expect(ingest(["ev": many]).count == JournalIngest.maxPerMessage)
        #expect(ingest("n'importe quoi").isEmpty)
        #expect(ingest(["ev": "pas une liste"]).isEmpty)
        #expect(ingest(["ev": [["e": "ptr.window"]]]).isEmpty)
    }
}
