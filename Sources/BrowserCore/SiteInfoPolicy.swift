import Foundation

/// What the "site information" popover says, decided without any UI so it can be tested.
public enum SiteInfoPolicy {
    public struct Connection: Equatable, Sendable {
        public var secure: Bool
        public var title: String
        public var detail: String
    }

    /// The origin string site permissions are stored under ("https://host", plus ":port" when it is not the default one).
    public static func origin(for url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host?.lowercased() else { return nil }
        let isDefault = (scheme == "https" && url.port == 443) || (scheme == "http" && url.port == 80)
        if let port = url.port, !isDefault { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    public static func connection(for url: URL?) -> Connection {
        switch url?.scheme?.lowercased() {
        case "https":
            return Connection(secure: true, title: "Connexion sécurisée", detail: "Ce que tu échanges avec ce site est chiffré en route.")
        case "http":
            return Connection(secure: false, title: "Connexion non sécurisée", detail: "Les échanges avec ce site ne sont pas chiffrés : n’y saisis ni mot de passe ni carte bancaire.")
        case "oree":
            return Connection(secure: true, title: "Page d’Orée", detail: "Cette page est fournie par Orée, pas par un site.")
        default:
            return Connection(secure: false, title: "Page locale ou spéciale", detail: "Aucune connexion à un site web.")
        }
    }

    /// "Valable encore 45 jours", "Valable jusqu'à demain", "Expiré depuis 3 jours".
    public static func validity(until date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case ..<0: return "Expiré depuis \(-days) jour\(days == -1 ? "" : "s")"
        case 0: return "Expire aujourd’hui"
        case 1: return "Valable jusqu’à demain"
        default: return "Valable encore \(days) jours"
        }
    }

    /// Whether a cookie's domain (".example.com", "www.example.com") belongs to `host`.
    public static func cookieDomain(_ domain: String, belongsTo host: String) -> Bool {
        let d = domain.lowercased().drop(while: { $0 == "." }), h = host.lowercased()
        return h == d || h.hasSuffix("." + d)
    }
}
