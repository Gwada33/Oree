import Foundation

/// The window a site's "username and password" request (HTTP basic, digest, NTLM) opens.
public enum HTTPAuthPolicy {
    /// Methods answered with a username and password. Server certificates and client certificates are left to the system.
    public static func asksForCredentials(method: String) -> Bool {
        [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM].contains(method)
    }

    public static func title(host: String, isProxy: Bool) -> String {
        isProxy ? "Le serveur mandataire « \(host) » demande une connexion" : "« \(host) » demande une connexion"
    }

    /// `realm` is the name the site gives to the protected area ("Administration"). `failed`: the previous answer was refused.
    public static func message(realm: String?, secure: Bool, failed: Bool) -> String {
        var lines: [String] = []
        if failed { lines.append("Nom d’utilisateur ou mot de passe refusé. Essaie encore.") }
        if let realm, !realm.isEmpty { lines.append("Zone protégée : « \(realm) ».") }
        if !secure { lines.append("Cette connexion n’est pas chiffrée : le mot de passe voyagerait en clair.") }
        return lines.joined(separator: "\n")
    }
}
