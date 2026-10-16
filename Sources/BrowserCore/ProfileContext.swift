import Foundation
import AppKit
import WebKit

/// Un profil d'Orée : un jeu complet et séparé de cookies, d'historique, de favoris, de mots de passe, de notes, d'extensions et de session (« Perso », « Travail »…).
public struct ProfileInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String           // 8 caractères hexadécimaux
    public var name: String
    public var createdAt: Date
    public init(id: String, name: String, createdAt: Date = Date()) { self.id = id; self.name = name; self.createdAt = createdAt }
}

/// La liste des profils (un petit fichier JSON) et leurs dossiers. Le profil « principal » n'a pas d'identifiant : il garde les données et les emplacements d'avant les profils.
public struct ProfileRegistry: Sendable {
    public let directory: URL
    public init(directory: URL = ProfileContext.baseDirectory) { self.directory = directory }
    private var file: URL { directory.appendingPathComponent("profiles.json") }

    public func list() -> [ProfileInfo] {
        (try? JSONDecoder().decode([ProfileInfo].self, from: Data(contentsOf: file))) ?? []
    }

    private func save(_ profiles: [ProfileInfo]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(profiles).write(to: file, options: .atomic)
    }

    public static func isValidID(_ id: String) -> Bool { id.count == 8 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
    public static func cleanName(_ name: String) -> String { String(name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ").prefix(30)) }

    /// Crée un profil (nom nettoyé, jamais vide, jamais en double).
    @discardableResult
    public func add(name: String) throws -> ProfileInfo {
        var profiles = list()
        var clean = Self.cleanName(name)
        if clean.isEmpty { clean = "Profil" }
        var candidate = clean, n = 2
        while profiles.contains(where: { $0.name.lowercased() == candidate.lowercased() }) || candidate.lowercased() == "principal" { candidate = "\(clean) \(n)"; n += 1 }
        let profile = ProfileInfo(id: String(format: "%08x", UInt32.random(in: .min ... .max)), name: candidate)
        profiles.append(profile)
        try save(profiles)
        try FileManager.default.createDirectory(at: folder(of: profile.id), withIntermediateDirectories: true)
        return profile
    }

    public func rename(id: String, to name: String) throws {
        var profiles = list()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let clean = Self.cleanName(name)
        guard !clean.isEmpty, !profiles.contains(where: { $0.id != id && $0.name.lowercased() == clean.lowercased() }) else { return }
        profiles[index].name = clean
        try save(profiles)
    }

    /// Retire un profil et ses données (le dossier). Le magasin de données web (cookies) est retiré par l'appelant.
    public func delete(id: String) throws {
        guard Self.isValidID(id) else { return }
        try save(list().filter { $0.id != id })
        try? FileManager.default.removeItem(at: folder(of: id))
    }

    public func folder(of id: String) -> URL { directory.appendingPathComponent(id, isDirectory: true) }
}

/// Un verrou par profil : un seul Orée à la fois par profil (deux instances du même profil écriraient dans la même base). Le fichier contient le numéro de processus ;
/// un numéro qui ne correspond plus à une instance d'Orée (plantage, numéro réutilisé par un autre programme) ne compte pas.
public enum ProfileLock {
    /// `isOree` : ce numéro de processus est-il bien une instance d'Orée vivante ? (injectable pour les tests)
    public static func holder(in folder: URL, isOree: (Int32) -> Bool = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier == Bundle.main.bundleIdentifier && Bundle.main.bundleIdentifier != nil }) -> Int32? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(".lock"), encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid != getpid(), isOree(pid) else { return nil }
        return pid
    }

    /// Prend le verrou. false : une autre instance d'Orée le tient déjà.
    public static func claim(in folder: URL, isOree: (Int32) -> Bool = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier == Bundle.main.bundleIdentifier && Bundle.main.bundleIdentifier != nil }) -> Bool {
        if holder(in: folder, isOree: isOree) != nil { return false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try? "\(getpid())".write(to: folder.appendingPathComponent(".lock"), atomically: true, encoding: .utf8)) != nil
    }

    public static func release(in folder: URL) {
        let url = folder.appendingPathComponent(".lock")
        if let text = try? String(contentsOf: url, encoding: .utf8), Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) == getpid() { try? FileManager.default.removeItem(at: url) }
    }
}

/// Le profil de CE lancement. Orée est lancé une fois par profil (`--profile <id>`) : chaque profil a son processus, donc ses propres cookies, sa base, sa session, ses extensions,
/// sans rien partager par accident. Sans argument : le profil principal, avec les emplacements d'avant les profils (rien n'est déplacé).
public enum ProfileContext {
    /// `HB_PROFILES_DIR` : dossier des profils pour les essais.
    public static var baseDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["HB_PROFILES_DIR"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/HyperBrowser/Profiles", isDirectory: true)
    }

    /// L'identifiant lu dans `--profile <id>` (ou `HB_PROFILE_ID`) ; nil pour le profil principal.
    public static let id: String? = {
        let args = CommandLine.arguments
        let raw = ProcessInfo.processInfo.environment["HB_PROFILE_ID"] ?? args.firstIndex(of: "--profile").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        return raw.flatMap { ProfileRegistry.isValidID($0) ? $0 : nil }
    }()

    public static var directory: URL? { id.map { ProfileRegistry().folder(of: $0) } }

    /// Où se pose le verrou : le dossier du profil, ou, pour le profil principal d'une vraie instance (pas un essai), le dossier de l'app.
    public static var lockFolder: URL? {
        if let directory { return directory }
        guard ProcessInfo.processInfo.environment["HB_DB_PATH"] == nil else { return nil }
        return mainFolder
    }

    public static var mainFolder: URL { baseDirectory.deletingLastPathComponent() }

    public static func folder(of id: String?) -> URL { id.map { ProfileRegistry().folder(of: $0) } ?? mainFolder }

    public static var name: String? { id.flatMap { id in ProfileRegistry().list().first { $0.id == id }?.name } }

    /// À ajouter aux clés de préférences qui décrivent la session et l'agencement : un profil, ou une instance d'essai (`HB_DB_PATH`), ne partage rien avec le principal.
    public static var keySuffix: String {
        if let id { return "." + id }
        return ProcessInfo.processInfo.environment["HB_DB_PATH"] == nil ? "" : ".bench"
    }

    /// Le dossier de cache d'images de veille : un par profil, pour qu'un Orée n'efface pas les images d'un autre.
    public static var cachesFolderName: String { id.map { "Orée-" + $0 } ?? "Orée" }

    /// Branche les emplacements du profil (base de données, extensions) AVANT que quoi que ce soit les lise. À appeler en toute première ligne.
    /// Renvoie false si une autre instance d'Orée tient déjà ce profil : l'appelant la ramène devant et quitte.
    @discardableResult
    public static func bootstrap(isOree: (Int32) -> Bool = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier == Bundle.main.bundleIdentifier && Bundle.main.bundleIdentifier != nil }) -> Bool {
        guard let folder = lockFolder else { return true }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard ProfileLock.claim(in: folder, isOree: isOree) else {
            if let pid = ProfileLock.holder(in: folder, isOree: isOree) { NSRunningApplication(processIdentifier: pid)?.activate() }
            return false
        }
        guard let id else { return true }
        if ProcessInfo.processInfo.environment["HB_DB_PATH"] == nil { setenv("HB_DB_PATH", folder.appendingPathComponent("browser.sqlite").path, 1) }
        if ProcessInfo.processInfo.environment["HB_EXT_DIR"] == nil { setenv("HB_EXT_DIR", folder.appendingPathComponent("Extensions", isDirectory: true).path, 1) }
        setenv("HB_PROFILE_ID", id, 1)
        return true
    }

    public static func release() { if let folder = lockFolder { ProfileLock.release(in: folder) } }

    /// Le magasin de données web (cookies, stockage local, cache) du profil : un magasin propre à chaque profil, le magasin par défaut pour le profil principal.
    @MainActor public static var dataStore: WKWebsiteDataStore {
        id.flatMap { UUID(uuidString: uuidString(for: $0)) }.map { WKWebsiteDataStore(forIdentifier: $0) } ?? .default()
    }

    /// L'identifiant de magasin d'un profil : « 0000000000000000000000AABBCCDDEE »-like, stable, déduit de l'identifiant du profil.
    public static func uuidString(for profileID: String) -> String {
        let hex = profileID.padding(toLength: 32, withPad: "0", startingAt: 0)
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20).prefix(12)]
        return parts.map(String.init).joined(separator: "-").uppercased()
    }
}
