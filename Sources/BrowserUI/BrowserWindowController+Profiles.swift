import AppKit
import BrowserCore

/// Les profils côté fenêtre : ouvrir un autre profil (un autre Orée, avec ses cookies, son historique, ses mots de passe), le dire dans la fenêtre, les proposer dans le menu du Dock et la palette.
extension BrowserWindowController {
    /// « Travail » ou nil pour le profil principal.
    var profileName: String? { ProfileContext.name }

    func applyProfileTitle() {
        window?.title = profileName.map { "Orée — \($0)" } ?? "Orée"
    }

    /// Ouvre un profil : s'il est déjà ouvert, sa fenêtre passe devant ; sinon un nouvel Orée se lance pour lui. `activates: false` pour les essais.
    public static func openProfile(id: String?, activates: Bool = true) {
        if id == ProfileContext.id { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil); return }
        if let pid = ProfileLock.holder(in: ProfileContext.folder(of: id)) { NSRunningApplication(processIdentifier: pid)?.activate(); return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = id.map { ["--profile", $0] } ?? []
        configuration.createsNewApplicationInstance = true
        configuration.activates = activates
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error { Log.tabs.error("Impossible d'ouvrir le profil : \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Profils proposés dans le menu du Dock et la palette : tous sauf celui-ci, plus le principal si l'on est dans un autre.
    func otherProfiles() -> [(id: String?, name: String)] {
        var list: [(String?, String)] = []
        if ProfileContext.id != nil { list.append((nil, "Principal")) }
        for profile in ProfileRegistry().list() where profile.id != ProfileContext.id { list.append((profile.id, profile.name)) }
        return list
    }

    func profileActions() -> [(String, String, @MainActor (BrowserWindowController) -> Void)] {
        var items: [(String, String, @MainActor (BrowserWindowController) -> Void)] = []
        for profile in otherProfiles() { items.append(("Ouvrir le profil : \(profile.name)", "person.crop.circle", { _ in BrowserWindowController.openProfile(id: profile.id) })) }
        items.append(("Nouveau profil…", "person.crop.circle.badge.plus", { $0.createProfile() }))
        return items
    }

    /// Demande un nom, crée le profil et l'ouvre.
    func createProfile() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Nouveau profil"
        alert.informativeText = "Un profil a ses propres cookies, son historique, ses favoris, ses mots de passe et ses extensions : par exemple un pour le travail et un pour la maison. Il s'ouvre dans sa propre fenêtre."
        alert.addButton(withTitle: "Créer"); alert.addButton(withTitle: "Annuler")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); field.placeholderString = "Travail"
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue
            MainActor.assumeIsolated {
                guard let profile = try? ProfileRegistry().add(name: name) else { return }
                BrowserWindowController.openProfile(id: profile.id)
            }
        }
    }
}
