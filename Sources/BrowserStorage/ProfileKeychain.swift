import Foundation
import Security

/// Le profil de l'utilisateur (nom, adresse…) pour les jetons `{{profil.xxx}}` : un seul élément du Trousseau (JSON), comme le coffre de mots de passe.
/// Rien n'est écrit sur disque ailleurs, et les valeurs ne sont jamais envoyées au modèle (le navigateur remplace les jetons après coup).
public struct ProfileKeychain: Sendable {
    private let service: String
    private let account = "profile"

    public init(service: String = "com.nolhan.hyperbrowser.profile") { self.service = service }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() -> [String: String] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    @discardableResult
    public func save(_ profile: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(profile) else { return false }
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "HyperBrowser — profil pour l'IA"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
