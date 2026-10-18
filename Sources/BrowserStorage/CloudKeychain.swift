import Foundation
import Security
import BrowserCore

/// La clé API d'un fournisseur d'IA en nuage (Mistral, Groq) : un élément du Trousseau (jamais dans un fichier du dépôt, ni dans les réglages en clair).
public struct CloudKeychain: Sendable {
    private let service: String
    private let account = "api-key"

    public init(service: String) { self.service = service }
    public init(_ provider: AIProvider) { self.init(service: provider.keychainService) }
    private var label: String { service.hasSuffix("mistral") ? "Mistral" : "Groq" }

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }

    /// Y a-t-il une clé ? Une requête sur les seuls attributs : elle ne déchiffre rien, donc le Trousseau ne demande jamais d'autorisation. Lire la valeur (`load`) la demande, et une app
    /// re-signée à chaque version la redemande : l'ancienne version de cette ligne gelait le fil principal 6 à 8 s à la première ouverture de Luciole (diagnostics du 17 octobre).
    public var hasKey: Bool {
        var query = base
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    @discardableResult
    public func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return delete() }
        let data = Data(trimmed.utf8)
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return true }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "HyperBrowser — clé API \(label)"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func delete() -> Bool {
        let status = SecItemDelete(base as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
