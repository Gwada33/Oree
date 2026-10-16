import Foundation
import CryptoKit
import GRDB
import BrowserCore

/// Adresses et cartes pour le remplissage automatique. Chaque enregistrement est chiffré (ChaCha20-Poly1305, clé du Trousseau) ; son type et son identifiant sont liés au chiffrement,
/// donc une boîte recopiée sur une autre ligne ne s'ouvre pas. Le libellé (« Maison ») est le seul texte en clair : il sert à afficher la liste sans déchiffrer.
public struct AutofillStore: Sendable {
    private let dbPool: DatabasePool
    private let keys: VaultKeyProvider

    public init(database: AppDatabase = .shared, keys: VaultKeyProvider = KeychainKeyProvider()) { self.dbPool = database.dbPool; self.keys = keys }

    private static func aad(_ kind: String, _ id: UUID) -> Data { Data("autofill\u{0}\(kind)\u{0}\(id.uuidString)".utf8) }

    private func put<T: Encodable>(_ value: T, kind: String, id: UUID, label: String) throws {
        let sealed = try ChaChaPoly.seal(JSONEncoder().encode(value), using: keys.masterKey(), authenticating: Self.aad(kind, id))
        try dbPool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO autofill (id, kind, label, sealed, updatedAt) VALUES (?, ?, ?, ?, ?)", arguments: [id.uuidString, kind, label, sealed.combined, Date()])
        }
    }

    private func all<T: Decodable>(_ type: T.Type, kind: String, id: (T) -> UUID) throws -> [T] {
        let rows = try dbPool.read { db in try Row.fetchAll(db, sql: "SELECT id, sealed FROM autofill WHERE kind = ? ORDER BY updatedAt DESC", arguments: [kind]) }
        let key = try keys.masterKey()
        return rows.compactMap { row in
            guard let idText: String = row["id"], let uuid = UUID(uuidString: idText), let blob: Data = row["sealed"],
                  let box = try? ChaChaPoly.SealedBox(combined: blob), let data = try? ChaChaPoly.open(box, using: key, authenticating: Self.aad(kind, uuid)) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
    }

    // MARK: Adresses
    public func save(_ address: AddressProfile) throws { try put(address, kind: "address", id: address.id, label: address.label) }
    public func addresses() throws -> [AddressProfile] { try all(AddressProfile.self, kind: "address") { $0.id } }

    // MARK: Cartes
    public func save(_ card: CardProfile) throws { try put(card, kind: "card", id: card.id, label: card.label) }
    public func cards() throws -> [CardProfile] { try all(CardProfile.self, kind: "card") { $0.id } }

    /// Les libellés sans rien déchiffrer : « combien de cartes ? » pour décider de proposer le menu.
    public func count(kind: String) -> Int {
        ((try? dbPool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM autofill WHERE kind = ?", arguments: [kind]) }) ?? 0) ?? 0
    }

    public func delete(id: UUID) throws { try dbPool.write { db in try db.execute(sql: "DELETE FROM autofill WHERE id = ?", arguments: [id.uuidString]) } }
    public func deleteAll() throws { try dbPool.write { db in try db.execute(sql: "DELETE FROM autofill") } }
}
