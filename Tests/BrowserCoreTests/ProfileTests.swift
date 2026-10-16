import Foundation
import Testing
@testable import BrowserCore

@Suite("Profils")
struct ProfileTests {
    private func registry() -> (ProfileRegistry, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString)")
        return (ProfileRegistry(directory: dir), dir)
    }

    @Test("créer, lister, renommer, supprimer ; le dossier du profil suit")
    func lifecycle() throws {
        let (registry, dir) = registry(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(registry.list().isEmpty)
        let work = try registry.add(name: "  Travail \n")
        #expect(work.name == "Travail" && ProfileRegistry.isValidID(work.id))
        #expect(FileManager.default.fileExists(atPath: registry.folder(of: work.id).path))
        try registry.rename(id: work.id, to: "Boulot")
        #expect(registry.list().map(\.name) == ["Boulot"])
        try "secret".write(to: registry.folder(of: work.id).appendingPathComponent("browser.sqlite"), atomically: true, encoding: .utf8)
        try registry.delete(id: work.id)
        #expect(registry.list().isEmpty && !FileManager.default.fileExists(atPath: registry.folder(of: work.id).path))
    }

    @Test("jamais de nom vide, de doublon ni de « Principal » ; les noms trop longs sont coupés ; un identifiant invalide ne supprime rien")
    func names() throws {
        let (registry, dir) = registry(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try registry.add(name: "   ").name == "Profil")
        #expect(try registry.add(name: "Profil").name == "Profil 2")
        #expect(try registry.add(name: "principal").name == "principal 2")
        #expect(try registry.add(name: String(repeating: "x", count: 100)).name.count == 30)
        let before = registry.list().count
        try registry.delete(id: "../../etc")
        #expect(registry.list().count == before)
        let one = registry.list()[0]
        try registry.rename(id: one.id, to: registry.list()[1].name)            // un nom déjà pris est refusé
        #expect(registry.list()[0].name == "Profil")
    }

    @Test("identifiants : 8 caractères hexadécimaux en minuscules, rien d'autre")
    func ids() {
        #expect(ProfileRegistry.isValidID("0a1b2c3d") && !ProfileRegistry.isValidID("0A1B2C3D") && !ProfileRegistry.isValidID("abc") && !ProfileRegistry.isValidID("../abcde") && !ProfileRegistry.isValidID(""))
        #expect(ProfileContext.uuidString(for: "0a1b2c3d") == "0A1B2C3D-0000-0000-0000-000000000000")
        #expect(UUID(uuidString: ProfileContext.uuidString(for: "ffffffff")) != nil)
        #expect(ProfileContext.uuidString(for: "00000001") != ProfileContext.uuidString(for: "00000002"))
    }

    @Test("un verrou pris par une instance d'Orée vivante bloque ; un numéro d'un autre programme ou d'un processus mort ne bloque pas")
    func locks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ProfileLock.claim(in: folder, isOree: { _ in false }))                          // personne : on le prend (notre numéro y est écrit)
        #expect(ProfileLock.holder(in: folder, isOree: { _ in true }) == nil)                  // c'est nous : pas un autre
        try "99999".write(to: folder.appendingPathComponent(".lock"), atomically: true, encoding: .utf8)
        #expect(ProfileLock.holder(in: folder, isOree: { $0 == 99999 }) == 99999)
        #expect(!ProfileLock.claim(in: folder, isOree: { $0 == 99999 }))                        // une autre instance d'Orée l'a : refusé
        #expect(ProfileLock.claim(in: folder, isOree: { _ in false }))                          // un numéro réutilisé par un autre programme : le verrou est périmé
        ProfileLock.release(in: folder)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".lock").path))
        try "99999".write(to: folder.appendingPathComponent(".lock"), atomically: true, encoding: .utf8)
        ProfileLock.release(in: folder)                                                         // on ne retire pas le verrou d'un autre
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".lock").path))
    }

    @Test("sans profil, les clés de préférences d'avant ne changent pas ; une instance d'essai garde son suffixe")
    func keys() {
        #expect(ProfileContext.id == nil)
        #expect(ProfileContext.keySuffix == (ProcessInfo.processInfo.environment["HB_DB_PATH"] == nil ? "" : ".bench"))
        #expect(ProfileContext.cachesFolderName == "Orée")
    }
}
