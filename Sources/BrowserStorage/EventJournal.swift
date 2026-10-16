import Foundation
import CryptoKit
import BrowserCore

/// Le journal d'événements : ce que l'app observe de la façon dont on s'en sert (onglets, navigation, survols, temps de chargement…), gardé sur ce Mac pour mesurer
/// et régler la vitesse d'Orée avec des chiffres réels. Rien n'est envoyé nulle part.
///
/// - Confidentialité : un événement n'entre que s'il passe le schéma (`JournalSchema.validate`) : champs fermés, nombres bornés, sites en empreintes. Pas d'adresse,
///   pas de titre, pas de texte, pas de touche. Les fichiers sont chiffrés (ChaCha20-Poly1305, clé dans le Trousseau) et protégés.
/// - Format : un fichier par jour (`journal-AAAA-MM-JJ.ojl`), des blocs `[longueur sur 4 octets][boîte chiffrée]`, chaque bloc contenant des lignes JSON.
/// - Écriture : un tampon en mémoire vidé toutes les 3 s (ou à 200 événements, ou à la fermeture), sur une file à part : aucune écriture sur le fil principal.
/// - Durée de garde : 30 jours par défaut, 100 Mo au plus ; le plus ancien part d'abord.
public final class EventJournal: @unchecked Sendable {
    public struct Stats: Equatable, Sendable {
        public var files = 0, events = 0
        public var bytes: Int64 = 0
        public var first: Date?, last: Date?
    }

    private let directory: URL
    private let keys: VaultKeyProvider
    private let queue = DispatchQueue(label: "oree.journal", qos: .utility)
    private var buffer: [JournalEvent] = []
    private var flushScheduled = false
    private var cachedKey: SymmetricKey?
    private let clock: @Sendable () -> Date
    private var lastPrunedDay = ""
    public var retentionDays: Int
    public var maxBytes: Int64
    public static let blockEvents = 200

    public init(directory: URL, keys: VaultKeyProvider, retentionDays: Int = 30, maxBytes: Int64 = 100 << 20, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory; self.keys = keys; self.retentionDays = retentionDays; self.maxBytes = maxBytes; self.clock = clock
    }

    /// Le journal de l'app : `Application Support/HyperBrowser/Journal`, clé du Trousseau `com.nolhan.hyperbrowser.journal`.
    /// Avec `override` (essais seulement : `HB_JOURNAL_DIR`), la clé est un fichier du dossier d'essai : un essai ne touche pas au Trousseau de la personne et n'y déclenche aucune demande d'accès.
    public static func standard(directory override: URL? = nil) -> EventJournal {
        if let override { return EventJournal(directory: override, keys: FileKeyProvider(file: override.appendingPathComponent(".test-key"))) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HyperBrowser/Journal", isDirectory: true)
        return EventJournal(directory: base, keys: KeychainKeyProvider(service: "com.nolhan.hyperbrowser.journal", account: "journal-key"))
    }

    // MARK: Clé

    private func masterKey() throws -> SymmetricKey {
        if let cachedKey { return cachedKey }
        let key = try keys.masterKey(); cachedKey = key; return key
    }

    /// La clé des empreintes de sites (déduite de la clé du journal), lue HORS du fil appelant : le Trousseau peut attendre une réponse de la personne (demande d'accès
    /// après une mise à jour de l'app), et l'interface ne doit jamais attendre avec lui. `completion` est appelée sur la file du journal ; rien si le Trousseau refuse.
    public func loadSiteKey(_ completion: @escaping @Sendable (SymmetricKey) -> Void) {
        queue.async { [self] in if let key = try? masterKey() { completion(SiteHash.key(from: key)) } }
    }

    /// Version bloquante, pour les essais et les outils (jamais depuis l'interface).
    public func siteKey() -> SymmetricKey? {
        queue.sync { (try? masterKey()).map(SiteHash.key(from:)) }
    }

    // MARK: Écriture

    /// Ajoute un événement (validé par le schéma). Peut être appelé depuis n'importe quel fil.
    public func record(_ event: JournalEvent) {
        guard let clean = JournalSchema.validate(event) else { return }
        queue.async { [self] in
            buffer.append(clean)
            if buffer.count >= Self.blockEvents { writeBuffer() }
            else if !flushScheduled {
                flushScheduled = true
                queue.asyncAfter(deadline: .now() + 3) { [self] in flushScheduled = false; writeBuffer() }
            }
        }
    }

    /// Vide le tampon maintenant et attend la fin de l'écriture (fermeture de l'app, export, essais).
    public func flushAndWait() { queue.sync { writeBuffer() } }

    private static func dayName(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func file(forDay day: String) -> URL { directory.appendingPathComponent("journal-\(day).ojl") }

    /// Doit être appelée sur `queue`.
    private func writeBuffer() {
        guard !buffer.isEmpty else { return }
        defer { buffer.removeAll(keepingCapacity: true) }
        guard let key = try? masterKey() else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Les événements d'un même jour vont dans le même fichier (un bloc ne traverse pas minuit).
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let byDay = Dictionary(grouping: buffer) { Self.dayName(Date(timeIntervalSince1970: $0.t)) }
            for (day, events) in byDay {
                let lines = try events.map { String(decoding: try encoder.encode($0), as: UTF8.self) }.joined(separator: "\n")
                let sealed = try ChaChaPoly.seal(Data(lines.utf8), using: key).combined
                var length = UInt32(sealed.count).bigEndian
                var block = Data(bytes: &length, count: 4); block.append(sealed)
                let url = file(forDay: day)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: block)
            }
        } catch { /* un journal qui ne peut pas s'écrire ne doit jamais gêner la navigation */ }
        let today = Self.dayName(clock())
        if today != lastPrunedDay { lastPrunedDay = today; prune() }
    }

    // MARK: Lecture

    private func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("journal-") && $0.pathExtension == "ojl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Les événements d'un fichier, dans l'ordre ; un bloc abîmé est sauté.
    private func events(in url: URL, key: SymmetricKey) -> [JournalEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        var out: [JournalEvent] = [], offset = 0
        let decoder = JSONDecoder()
        while offset + 4 <= data.count {
            let length = Int(data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
            offset += 4
            guard length > 0, offset + length <= data.count else { break }
            let blob = data.subdata(in: offset..<offset + length); offset += length
            guard let box = try? ChaChaPoly.SealedBox(combined: blob), let plain = try? ChaChaPoly.open(box, using: key) else { continue }
            for line in String(decoding: plain, as: UTF8.self).split(separator: "\n") {
                if let event = try? decoder.decode(JournalEvent.self, from: Data(line.utf8)) { out.append(event) }
            }
        }
        return out
    }

    /// Tous les événements gardés (déchiffrés, en mémoire : pour l'export et les essais).
    public func readAll() -> [JournalEvent] {
        flushAndWait()
        return queue.sync {
            guard let key = try? masterKey() else { return [] }
            return files().flatMap { events(in: $0, key: key) }
        }
    }

    public func stats() -> Stats {
        flushAndWait()
        return queue.sync {
            var stats = Stats()
            guard let key = try? masterKey() else { return stats }
            for url in files() {
                stats.files += 1
                stats.bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let list = events(in: url, key: key)
                stats.events += list.count
                if let first = list.first?.t, stats.first == nil { stats.first = Date(timeIntervalSince1970: first) }
                if let last = list.last?.t { stats.last = Date(timeIntervalSince1970: last) }
            }
            return stats
        }
    }

    // MARK: Export, effacement, durée de garde

    /// Écrit le journal déchiffré en JSON Lines (une première ligne décrit le format). Le fichier obtenu n'est PAS chiffré : à garder où l'on veut, avec ce que cela implique.
    @discardableResult
    public func export(to url: URL) throws -> Int {
        let all = readAll()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let header = "{\"format\":\"oree-journal\",\"schema\":\(JournalSchema.version),\"note\":\"Les sites sont des empreintes (HMAC) propres à ce Mac ; aucune adresse, aucun titre, aucun texte.\",\"events\":\(all.count)}"
        let body = try all.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try ([header] + body).joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return all.count
    }

    /// Efface tout : les fichiers, et ce qui attendait dans le tampon.
    public func clear() {
        queue.sync {
            buffer.removeAll()
            for url in files() { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Retire ce qui dépasse la durée de garde, puis les plus vieux fichiers tant que le dossier dépasse sa taille.
    public func prune() {
        let limit = clock().addingTimeInterval(-Double(retentionDays) * 86_400)
        let oldest = Self.dayName(limit)
        var list = files()
        for url in list where url.deletingPathExtension().lastPathComponent.dropFirst("journal-".count) < Substring(oldest) { try? FileManager.default.removeItem(at: url) }
        list = files()
        var total = list.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        for url in list where total > maxBytes {
            total -= Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Une clé gardée dans un fichier : seulement pour les essais (le vrai journal utilise le Trousseau).
public struct FileKeyProvider: VaultKeyProvider {
    private let file: URL
    public init(file: URL) { self.file = file }
    public func masterKey() throws -> SymmetricKey {
        if let data = try? Data(contentsOf: file), data.count == 32 { return SymmetricKey(data: data) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let key = SymmetricKey(size: .bits256)
        try key.withUnsafeBytes { try Data($0).write(to: file, options: .atomic) }
        return key
    }
}
