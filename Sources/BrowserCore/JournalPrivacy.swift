import Foundation
import CryptoKit

/// Les sites ne sont jamais écrits dans le journal : seulement une empreinte (HMAC-SHA-256 du domaine avec une clé propre à ce Mac, 8 octets). On peut ainsi
/// compter « le même site » sans pouvoir retrouver de quel site il s'agit sans la clé. Les adresses complètes, les titres et les textes n'y entrent jamais.
public enum SiteHash {
    /// Domaines publics à deux niveaux (« co.uk ») : le domaine de site en prend trois étiquettes. Liste volontairement courte.
    static let twoLevelSuffixes: Set<String> = ["co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.jp", "com.br", "co.nz", "co.in", "gouv.fr", "com.cn", "com.mx", "co.za", "com.tr", "com.ar"]

    /// « fr.wikipedia.org » → « wikipedia.org » ; « impots.gouv.fr » → « impots.gouv.fr » ; « localhost » → « localhost » ; une adresse IP reste entière.
    public static func registrableDomain(_ host: String) -> String {
        let lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let labels = lower.split(separator: ".").map(String.init)
        guard labels.count > 2, !lower.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) else { return lower }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        return twoLevelSuffixes.contains(lastTwo) ? labels.suffix(3).joined(separator: ".") : lastTwo
    }

    /// 16 caractères hexadécimaux.
    public static func hash(host: String, key: SymmetricKey) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(registrableDomain(host).utf8), using: key)
        return mac.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// La clé des empreintes se déduit de la clé du journal (HKDF) : une seule clé à garder, et effacer le journal avec sa clé rend les empreintes inversibles à personne.
    public static func key(from master: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Data("oree.journal.site".utf8), info: Data("site-hash-v1".utf8), outputByteCount: 32)
    }

    /// Un identifiant d'onglet : 4 caractères hexadécimaux au hasard, valable le temps d'un lancement.
    public static func randomTabID() -> String { String(format: "%04x", UInt16.random(in: .min ... .max)) }
}

/// Des mesures en classes plutôt qu'en valeurs exactes quand l'exact n'apporte rien et pourrait trahir (longueur d'un texte, taille d'un fichier).
public enum JournalBucket {
    /// 0 pour 0, puis 1 + log2 : 1→1, 2–3→2, 4–7→3 … plafonné à 12.
    public static func log2(_ value: Int) -> Int {
        guard value > 0 else { return 0 }
        return min(12, 1 + Int(Foundation.log2(Double(value))))
    }
    /// Une case de grille 10 × 10 (0…9) pour une position dans la fenêtre : où sont les liens que l'on survole, sans garder un pixel.
    public static func cell(_ position: Double, of extent: Double) -> Int {
        guard extent > 0 else { return 0 }
        return min(9, max(0, Int(position / extent * 10)))
    }
    /// Une largeur ou une hauteur arrondie à la centaine de points.
    public static func hundreds(_ points: Double) -> Int { max(0, Int((points / 100).rounded())) }
}


/// Qui a le droit d'être observé : une page web ordinaire d'un onglet ordinaire.
public enum JournalPolicy {
    public static func allowsPage(url: URL?, isPrivate: Bool) -> Bool {
        guard !isPrivate, let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return !ActionPolicy.isForbiddenPage(url)
    }
}

/// Les messages que le script du journal envoie depuis une page : ils viennent d'une source non fiable (la page peut mentir), donc tout est reconstruit ici :
/// seuls les événements prévus passent, les adresses deviennent des empreintes, et le schéma fixe les bornes de chaque champ.
public enum JournalIngest {
    static let fromPage: Set<String> = ["page.shape", "page.perf", "page.leave", "link.hover", "link.click", "ptr.window", "ptr.click", "scroll.window", "key.window", "field.focus", "text.select"]
    public static let maxPerMessage = 40

    public static func events(from body: Any, tab: String, pageSite: String, now: Double, hash: (String) -> String) -> [JournalEvent] {
        guard let list = (body as? [String: Any])?["ev"] as? [[String: Any]] else { return [] }
        var out: [JournalEvent] = []
        for item in list.prefix(maxPerMessage) {
            guard let name = item["e"] as? String, fromPage.contains(name), let raw = item["d"] as? [String: Any] else { continue }
            var d: [String: JournalValue] = [:]
            for (key, value) in raw {
                switch value {
                case let v as Bool: d[key] = .bool(v)
                case let v as Int: d[key] = .int(v)
                case let v as Double: d[key] = .double(v)
                case let v as String where key != "host": d[key] = .string(String(v.prefix(32)))
                default: break
                }
            }
            d["tab"] = .string(tab)
            if name.hasPrefix("page.") { d["site"] = .string(pageSite) }
            if name.hasPrefix("link."), let host = raw["host"] as? String, !host.isEmpty, host.count <= 253 {
                let site = hash(host)
                d["site"] = .string(site)
                d["same"] = .bool(site == pageSite)
                d["external"] = .bool(site != pageSite)
            }
            if let event = JournalSchema.validate(JournalEvent(t: now, e: name, d: d)) { out.append(event) }
        }
        return out
    }
}
