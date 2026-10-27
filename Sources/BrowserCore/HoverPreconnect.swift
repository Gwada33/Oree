import Foundation

/// Préconnexion au survol d'un lien : quand le pointeur reste assez longtemps sur un lien, on ouvre la connexion au serveur avant le clic.
/// Les délais viennent du journal d'usage (13 914 survols) : par genre de lien, le délai qui couvre ~80-90 % des clics avec le moins de préconnexions inutiles.
public enum HoverPreconnect {
    /// Millisecondes de survol avant de préconnecter.
    public static func delay(kind: String) -> Int {
        switch kind {
        case "nav", "other": 200       // 36 % de clics parmi les survols ≥ 200 ms, 87 % des clics couverts
        case "button": 250
        default: 350                   // « content » : 8 % seulement de clics, donc plus patient
        }
    }

    /// Seulement http(s), jamais dans un onglet privé, jamais en économie d'énergie.
    public static func allows(_ url: URL, isPrivate: Bool, lowPower: Bool) -> Bool {
        guard !isPrivate, !lowPower, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// Une seule préconnexion par serveur dans la fenêtre `ttl` (la connexion ouverte reste utilisable un moment).
    public final class Recent {
        private var last: [String: Date] = [:]
        public init() {}
        public func shouldConnect(host: String, now: Date = Date(), ttl: TimeInterval = 20) -> Bool {
            if let t = last[host], now.timeIntervalSince(t) < ttl { return false }
            if last.count > 200 { last = last.filter { now.timeIntervalSince($0.value) < ttl } }
            last[host] = now
            return true
        }
    }
}
