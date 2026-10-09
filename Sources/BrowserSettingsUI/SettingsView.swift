import SwiftUI
import Combine
import WebKit
import BrowserCore
import BrowserStorage
import AppKit

/// The only SwiftUI screen in the app, per project convention — everything
/// else (tabs, web view hosting) stays AppKit for fluidity.
///
/// Uses the pre-macro `ObservableObject`/`@Published` state pattern rather
/// than `@State`/`@Observable`: those newer property wrappers are
/// implemented as Swift macros, and the macro plugin that expands them
/// (`SwiftUIMacros`) ships inside full Xcode, not the standalone Command
/// Line Tools this was built with. `ObservableObject` predates the macro
/// system and needs nothing but the SDK, so it's what actually builds here.
/// Worth revisiting once Xcode is installed.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, appearance, layout, privacy, passwords, shortcuts, downloads, extensions, data, advanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "Général"
        case .privacy: return "Confidentialité"
        case .passwords: return "Mots de passe"
        case .appearance: return "Apparence"
        case .layout: return "Disposition"
        case .downloads: return "Téléchargements"
        case .shortcuts: return "Raccourcis clavier"
        case .extensions: return "Extensions"
        case .data: return "Données"
        case .advanced: return "Avancé"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .privacy: return "hand.raised"
        case .passwords: return "key"
        case .appearance: return "paintbrush"
        case .layout: return "sidebar.left"
        case .downloads: return "arrow.down.to.line"
        case .shortcuts: return "command"
        case .extensions: return "puzzlepiece.extension"
        case .data: return "externaldrive"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    private let settings = SettingsStore.shared
    private let historyRepo = HistoryRepository()
    private let bookmarkRepo = BookmarkRepository()
    private let permissionRepo = SitePermissionRepository()
    private let vault = CredentialVault()
    let onPinnedSitesChanged: () -> Void
    let onUpdateFilterLists: () -> Void
    private let extensionsProvider: (any ExtensionsProviding)?
    @Published var installedExtensions: [ExtensionInfo] = []
    @Published var extensionMessage: String?

    @Published var searchEngine: SearchEngine { didSet { settings.searchEngine = searchEngine } }
    @Published var homepageURL: String {
        didSet { settings.customHomepageURL = homepageURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    @Published var adBlockEnabled: Bool { didSet { settings.adBlockEnabled = adBlockEnabled } }
    @Published var privateByDefault: Bool { didSet { settings.privateByDefault = privateByDefault } }
    @Published var autoplayAllowed: Bool { didSet { settings.autoplayMediaAllowed = autoplayAllowed } }
    @Published var autoSuspendMinutes: Int { didSet { settings.autoSuspendMinutes = autoSuspendMinutes } }
    @Published var freezeAfterSeconds: Int { didSet { settings.freezeAfterSeconds = freezeAfterSeconds } }
    @Published var httpsOnly: Bool { didSet { settings.httpsOnly = httpsOnly } }
    @Published var urlCleaning: Bool { didSet { settings.urlCleaning = urlCleaning } }
    @Published var fingerprintProtection: Bool { didSet { settings.fingerprintProtection = fingerprintProtection } }
    @Published var safeBrowsingEnabled: Bool { didSet { settings.safeBrowsingEnabled = safeBrowsingEnabled } }
    @Published var safeBrowsingKey: String { didSet { settings.safeBrowsingAPIKey = safeBrowsingKey } }
    // HB_SETTINGS_CATEGORY: lets screenshot tests open straight on a category.
    @Published var isDefaultBrowser = false
    @Published var category: SettingsCategory = ProcessInfo.processInfo.environment["HB_SETTINGS_CATEGORY"].flatMap(SettingsCategory.init(rawValue:)) ?? .general
    @Published var storedPermissions: [StoredPermission] = []
    @Published var learnSiteMemory: Bool { didSet { settings.learnSiteMemory = learnSiteMemory } }
    @Published var heaviestSites: [SiteProfile] = []
    private let siteMemoryRepo = SiteMemoryRepository()
    @Published var lightLongPages: Bool { didSet { settings.lightLongPages = lightLongPages } }
    @Published var backgroundCleanup: Bool { didSet { settings.backgroundCleanup = backgroundCleanup } }
    @Published var autoUpdateCheck: Bool { didSet { settings.autoUpdateCheck = autoUpdateCheck } }
    @Published var memoryBudgetMB: Int { didSet { settings.memoryBudgetMB = memoryBudgetMB } }
    @Published var instantBack: Bool { didSet { settings.instantBack = instantBack } }
    @Published var startPageShowsRecent: Bool { didSet { settings.startPageShowsRecent = startPageShowsRecent } }
    @Published var webInspectorEnabled: Bool { didSet { settings.webInspectorEnabled = webInspectorEnabled } }
    @Published var savedLogins: [SavedLogin] = []
    @Published var newLoginSite = ""
    @Published var newLoginUser = ""
    @Published var newLoginPassword = ""
    @Published var passwordMessage: String?
    @Published var importResultMessage: String?
    @Published var cookieImportMessage: String?
    @Published var cookieImportRunning = false
    @Published var pendingDestructiveAction: DestructiveAction?

    enum DestructiveAction: Identifiable {
        case clearHistory, clearCookies, clearBookmarks
        var id: Self { self }
    }

    init(onPinnedSitesChanged: @escaping () -> Void, onUpdateFilterLists: @escaping () -> Void, extensions: (any ExtensionsProviding)?) {
        self.onPinnedSitesChanged = onPinnedSitesChanged
        self.onUpdateFilterLists = onUpdateFilterLists
        self.extensionsProvider = extensions
        let current = SettingsStore.shared
        httpsOnly = current.httpsOnly
        urlCleaning = current.urlCleaning
        fingerprintProtection = current.fingerprintProtection
        safeBrowsingEnabled = current.safeBrowsingEnabled
        safeBrowsingKey = current.safeBrowsingAPIKey
        webInspectorEnabled = current.webInspectorEnabled
        startPageShowsRecent = current.startPageShowsRecent
        instantBack = current.instantBack
        memoryBudgetMB = current.memoryBudgetMB
        backgroundCleanup = current.backgroundCleanup
        autoUpdateCheck = current.autoUpdateCheck
        lightLongPages = current.lightLongPages
        learnSiteMemory = current.learnSiteMemory
        searchEngine = current.searchEngine
        homepageURL = current.customHomepageURL
        adBlockEnabled = current.adBlockEnabled
        privateByDefault = current.privateByDefault
        autoplayAllowed = current.autoplayMediaAllowed
        autoSuspendMinutes = current.autoSuspendMinutes
        freezeAfterSeconds = current.freezeAfterSeconds
        reloadPermissions()
        reloadLogins()
        refreshDefaultBrowser()
        reloadExtensions()
        reloadHeaviestSites()
    }

    func refreshDefaultBrowser() {
        let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        isDefaultBrowser = handler?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// macOS asks the user to confirm; nothing changes until they do.
    func makeDefaultBrowser() {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { [weak self] _ in
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in
                Task { @MainActor in self?.refreshDefaultBrowser() }
            }
        }
    }

    // MARK: Extensions

    var canManageExtensions: Bool { extensionsProvider != nil }

    func reloadExtensions() { installedExtensions = extensionsProvider?.installedExtensions() ?? [] }

    func addExtension() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choisissez un dossier d'extension décompressé, un fichier .zip ou un fichier .crx."
        panel.prompt = "Installer"
        guard panel.runModal() == .OK, let url = panel.url, let provider = extensionsProvider else { return }
        extensionMessage = "Installation…"
        Task {
            do {
                try await provider.install(from: url)
                extensionMessage = nil
            } catch is CancellationError {
                extensionMessage = nil
            } catch ExtensionPackageError.notAnExtension {
                extensionMessage = "Ce n'est pas une extension : fichier manifest.json introuvable."
            } catch ExtensionPackageError.badCRX {
                extensionMessage = "Fichier .crx illisible."
            } catch {
                extensionMessage = "Installation impossible : \(error.localizedDescription)"
            }
            reloadExtensions()
        }
    }

    func setExtension(_ id: String, enabled: Bool) {
        extensionsProvider?.setEnabled(enabled, id: id)
        reloadExtensions()
    }

    func removeExtension(_ id: String) {
        extensionsProvider?.remove(id: id)
        reloadExtensions()
    }

    func reloadLogins() {
        savedLogins = (try? vault.allLogins()) ?? []
    }

    func deleteLogin(_ login: SavedLogin) {
        try? vault.delete(id: login.id)
        reloadLogins()
    }

    /// Copies a password after Touch ID, and clears the clipboard 30 s later
    /// (only if nothing else was copied in the meantime).
    func copyPassword(of login: SavedLogin) {
        Task {
            guard await VaultUnlocker.shared.authenticate(reason: "Copier le mot de passe de \(login.username)"),
                  let password = try? vault.password(origin: login.origin, username: login.username) else {
                passwordMessage = "Authentification refusée ou mot de passe illisible."
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(password, forType: .string)
            let count = pasteboard.changeCount
            passwordMessage = "Mot de passe copié (effacé du presse-papiers dans 30 s)."
            try? await Task.sleep(for: .seconds(30))
            if pasteboard.changeCount == count { pasteboard.clearContents() }
        }
    }

    /// Imports a CSV exported from Apple's Passwords app (or Chrome, Firefox…).
    func importPasswordCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "Choisissez le fichier CSV exporté depuis l'app Mots de passe (Fichier > Exporter tous les mots de passe)."
        panel.prompt = "Importer"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            let result = try PasswordCSVImporter.parse(try String(contentsOf: file, encoding: .utf8))
            let count = try vault.importEntries(result.entries)
            passwordMessage = "\(count) mot(s) de passe importé(s)" + (result.skipped > 0 ? ", \(result.skipped) ignoré(s) (site non sécurisé ou incomplet)." : ".")
            reloadLogins()
            offerToTrash(file)
        } catch PasswordCSVImporter.ImportError.missingColumns {
            passwordMessage = "Ce fichier n'a pas les colonnes attendues (URL, Identifiant, Mot de passe)."
        } catch {
            passwordMessage = "Import impossible : \(error.localizedDescription)"
        }
    }

    /// The export holds every password in plain text — offer to bin it right away.
    private func offerToTrash(_ file: URL) {
        let alert = NSAlert()
        alert.messageText = "Mettre le fichier CSV à la corbeille ?"
        alert.informativeText = "Il contient vos mots de passe en clair. Une fois importés dans HyperBrowser, vous n'en avez plus besoin."
        alert.addButton(withTitle: "Mettre à la corbeille")
        alert.addButton(withTitle: "Garder")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.recycle([file]) { _, _ in }
        }
    }

    func addLogin() {
        let site = newLoginSite.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !site.isEmpty, !newLoginPassword.isEmpty else { return }
        let withScheme = site.contains("://") ? site : "https://\(site)"
        guard let url = URL(string: withScheme), let origin = SitePermissionRepository.origin(for: url) else {
            passwordMessage = "Adresse invalide."
            return
        }
        do {
            try vault.save(origin: origin, username: newLoginUser, password: newLoginPassword)
            newLoginSite = ""; newLoginUser = ""; newLoginPassword = ""
            passwordMessage = nil
            reloadLogins()
        } catch {
            passwordMessage = "Impossible d'enregistrer : \(error)"
        }
    }

    func reloadPermissions() {
        storedPermissions = (try? permissionRepo.all()) ?? []
    }

    func resetPermission(_ item: StoredPermission) {
        try? permissionRepo.reset(origin: item.origin, permission: item.permission)
        reloadPermissions()
    }

    func clearHistory() {
        try? historyRepo.clear()
        clearSiteMemory()
    }

    func reloadHeaviestSites() { heaviestSites = (try? siteMemoryRepo.heaviest(limit: 5)) ?? [] }

    func clearSiteMemory() {
        try? siteMemoryRepo.clear()
        reloadHeaviestSites()
    }

    func clearCookies() {
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    /// Offered whenever Brave is installed (its data folder may be unreadable until the user allows it).
    var braveCookiesAvailable: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Brave Browser.app") || ChromiumCookies.braveCookieDatabase != nil
            || !ChromiumCookies.canRead(ChromiumCookies.braveRoot) && FileManager.default.fileExists(atPath: ChromiumCookies.braveRoot.path)
    }

    /// Copies the user's Brave cookies into this browser (after an explicit confirmation).
    /// macOS asks for permission to read "Brave Safe Storage" in the Keychain; refusing aborts.
    func importBraveCookies() {
        let alert = NSAlert()
        alert.messageText = "Importer les cookies de Brave ?"
        alert.informativeText = "Vous resterez connecté aux mêmes sites que dans Brave. macOS va vous demander l'autorisation de lire la clé « Brave Safe Storage » du Trousseau : refusez si vous n'en voulez pas. Les cookies restent sur ce Mac et ne sont ni affichés ni envoyés nulle part. Les cookies déjà présents avec le même nom sont remplacés."
        alert.addButton(withTitle: "Importer")
        alert.addButton(withTitle: "Annuler")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // macOS protects other apps' data: if the folder can't be listed, ask the user to pick it (that grants access).
        var root = ChromiumCookies.braveRoot
        if !ChromiumCookies.canRead(root) {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.directoryURL = root.deletingLastPathComponent()
            panel.prompt = "Autoriser"
            panel.message = "macOS protège les données de Brave. Choisissez le dossier « Brave-Browser » (Bibliothèque ▸ Application Support ▸ BraveSoftware) pour autoriser la lecture. Astuce : ⌘⇧G puis collez ~/Library/Application Support/BraveSoftware."
            guard panel.runModal() == .OK, var picked = panel.url else {
                cookieImportMessage = "Accès au dossier de Brave non accordé : rien n'a été importé."
                return
            }
            // Accept either the BraveSoftware folder or the Brave-Browser folder inside it.
            let inner = picked.appendingPathComponent("Brave-Browser")
            if !ChromiumCookies.hasCookieDatabase(picked), ChromiumCookies.hasCookieDatabase(inner) { picked = inner }
            _ = picked.startAccessingSecurityScopedResource()
            root = picked
        }
        cookieImportRunning = true
        cookieImportMessage = nil
        let chosenRoot = root
        Task { @MainActor in
            defer { cookieImportRunning = false }
            let result = await Task.detached { Result { try ChromiumCookies.importFromBrave(root: chosenRoot) } }.value
            switch result {
            case .failure(ChromiumCookieError.keychainDenied):
                cookieImportMessage = "Accès au Trousseau refusé : rien n'a été importé."
            case .failure(ChromiumCookieError.folderNotReadable):
                cookieImportMessage = "macOS bloque la lecture du dossier de Brave. Autorisez Orée dans Réglages Système ▸ Confidentialité et sécurité ▸ Accès complet au disque, ou réessayez et choisissez le dossier."
            case .failure(ChromiumCookieError.databaseNotFound):
                cookieImportMessage = "Aucun profil Brave trouvé sur ce Mac."
            case .failure:
                cookieImportMessage = "Impossible de lire les cookies de Brave (fermez Brave et réessayez)."
            case .success(let cookies):
                let store = WKWebsiteDataStore.default().httpCookieStore
                var added = 0
                for imported in cookies {
                    guard let cookie = Self.httpCookie(from: imported) else { continue }
                    await store.setCookie(cookie)
                    added += 1
                }
                cookieImportMessage = "\(added) cookie(s) importé(s) depuis Brave. Rechargez vos onglets pour en profiter."
            }
        }
    }

    private static func httpCookie(from c: ImportedCookie) -> HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [.domain: c.host, .path: c.path, .name: c.name, .value: c.value]
        if let expires = c.expires { props[.expires] = expires }
        if c.isSecure { props[.secure] = "TRUE" }
        if c.isHTTPOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let site = c.sameSite { props[.sameSitePolicy] = site == "strict" ? HTTPCookieStringPolicy.sameSiteStrict : HTTPCookieStringPolicy.sameSiteLax }
        return HTTPCookie(properties: props)
    }

    func clearBookmarks() {
        try? bookmarkRepo.clear()
        onPinnedSitesChanged()
    }

    func detectedBrowsers() -> [SourceBrowser] {
        BrowserImporter.detectInstalledBrowsers()
    }

    func importBookmarks(from browser: SourceBrowser) {
        let imported = BrowserImporter.importBookmarks(from: browser)
        for bookmark in imported {
            try? bookmarkRepo.add(url: bookmark.url, title: bookmark.title)
        }
        onPinnedSitesChanged()
        importResultMessage = imported.isEmpty
            ? "Rien importé depuis \(browser.displayName) — macOS bloque peut-être l'accès (Accès complet au disque dans Réglages Système)."
            : "\(imported.count) favori(s) importé(s) depuis \(browser.displayName)."
    }
}

public struct SettingsView: View {
    @ObservedObject private var model: SettingsViewModel
    private let onOpenCustomize: () -> Void

    private let autoSuspendOptions: [(label: String, minutes: Int)] = [
        ("5 minutes", 5), ("10 minutes", 10), ("20 minutes", 20),
        ("30 minutes", 30), ("45 minutes", 45), ("1 heure", 60), ("Jamais", 0),
    ]
    private let freezeOptions: [(label: String, seconds: Int)] = [
        ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300), ("10 minutes", 600), ("Jamais", 0),
    ]

    @MainActor
    public init(onPinnedSitesChanged: @escaping () -> Void, onUpdateFilterLists: @escaping () -> Void = {}, onOpenCustomize: @escaping () -> Void = {}, extensions: (any ExtensionsProviding)? = nil) {
        self.onOpenCustomize = onOpenCustomize
        model = SettingsViewModel(onPinnedSitesChanged: onPinnedSitesChanged, onUpdateFilterLists: onUpdateFilterLists, extensions: extensions)
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Form {
                switch model.category {
                case .general: generalSections
                case .privacy: privacySections
                case .passwords: passwordSections
                case .shortcuts: ShortcutsSection()
                case .appearance: AppearanceSection(onOpenCustomize: onOpenCustomize)
                case .layout: LayoutSection()
                case .downloads: DownloadsSection()
                case .extensions: extensionsSections
                case .data: dataSections
                case .advanced: advancedSections
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(OreeColor.chrome)
        }
        .tint(OreeColor.accent)
        .frame(minWidth: 760, minHeight: 560)
        .confirmationDialog(
            "Cette action est irréversible.",
            isPresented: Binding(
                get: { model.pendingDestructiveAction != nil },
                set: { if !$0 { model.pendingDestructiveAction = nil } }
            ),
            presenting: model.pendingDestructiveAction
        ) { action in
            Button("Confirmer", role: .destructive) { perform(action) }
            Button("Annuler", role: .cancel) {}
        }
    }


    @ViewBuilder private var generalSections: some View {
            Section("Navigateur par défaut") {
                if model.isDefaultBrowser {
                    Label("Orée est votre navigateur par défaut.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Button("Définir Orée comme navigateur par défaut") { model.makeDefaultBrowser() }
                    Text("Les liens cliqués dans d'autres applications s'ouvriront ici. macOS vous demandera de confirmer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Mises à jour") {
                Toggle("Rechercher automatiquement les mises à jour (une fois par jour)", isOn: $model.autoUpdateCheck)
                Text("Contacte github.com pour lire la dernière version publiée ; rien d'autre n'est envoyé. Vous pouvez aussi vérifier à la main : menu Orée → Rechercher des mises à jour…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Recherche") {
                Picker("Moteur de recherche", selection: $model.searchEngine) {
                    ForEach(SearchEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
            }
            Section("Page de démarrage") {
                TextField("Page d'accueil", text: $model.homepageURL, prompt: Text("https://exemple.com (vide = page intégrée)"))
                Toggle("Afficher les sites récents sur la page de nouvel onglet", isOn: $model.startPageShowsRecent)
            }
            Section("Performance") {
                Picker("Budget mémoire des onglets", selection: $model.memoryBudgetMB) {
                    Text("Automatique (un quart de la RAM)").tag(0)
                    Text("1 Go").tag(1024)
                    Text("2 Go").tag(2048)
                    Text("3 Go").tag(3072)
                    Text("4 Go").tag(4096)
                    Text("Illimité").tag(-1)
                }
                Text("Au-delà, les onglets cachés les plus lourds sont mis en veille (jamais l'onglet actif ni un onglet qui joue du son).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Apprendre le poids des sites (reste sur ce Mac)", isOn: $model.learnSiteMemory)
                Text("Retient, pour chaque site, la mémoire qu'il utilise d'habitude. Quand vous ouvrez un site réputé lourd, les onglets cachés sont mis en veille à l'avance pour lui faire de la place, et ces sites dorment plus vite quand vous les quittez.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.learnSiteMemory && !model.heaviestSites.isEmpty {
                    ForEach(model.heaviestSites, id: \.host) { site in
                        HStack {
                            Text(site.host)
                            Spacer()
                            Text("~\(Int(site.averageMB)) Mo en moyenne, jusqu'à \(Int(site.peakMB)) Mo")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Oublier ce que le navigateur a appris", role: .destructive) { model.clearSiteMemory() }
                Toggle("Pages longues plus légères (expérimental)", isOn: $model.lightLongPages)
                Text("Ne calcule pas l'affichage des éléments très éloignés de l'écran sur les longues listes (flux, résultats). Moins de mémoire et d'attente, mais peut rogner un menu qui dépasse d'un élément. S'applique aux pages ouvertes ensuite.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Nettoyer la mémoire JavaScript des onglets cachés (expérimental)", isOn: $model.backgroundCleanup)
                Text("Libère de la mémoire sur certains sites lourds ; peut provoquer de brèves saccades. Le budget mémoire utilise ce nettoyage de toute façon avant de mettre un onglet en veille.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Retour instantané (garde les pages précédentes en mémoire)", isOn: $model.instantBack)
                Text("Utilise nettement plus de mémoire quand vous naviguez beaucoup. Pris en compte au prochain lancement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Mettre en pause les onglets cachés après", selection: $model.freezeAfterSeconds) {
                    ForEach(freezeOptions, id: \.seconds) { option in
                        Text(option.label).tag(option.seconds)
                    }
                }
                Text("En pause : la page reste en mémoire mais ne calcule plus ; elle reprend instantanément. Un onglet avec une saisie non enregistrée n'est jamais déchargé, seulement mis en pause.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Décharger les onglets inactifs après", selection: $model.autoSuspendMinutes) {
                    ForEach(autoSuspendOptions, id: \.minutes) { option in
                        Text(option.label).tag(option.minutes)
                    }
                }
            }
    }

    @ViewBuilder private var privacySections: some View {
            Section("Confidentialité") {
                Toggle("Bloquer les publicités et traqueurs", isOn: $model.adBlockEnabled)
                Toggle("Ouvrir les nouveaux onglets en navigation privée par défaut", isOn: $model.privateByDefault)
                Toggle("Autoriser la lecture automatique des vidéos et sons", isOn: $model.autoplayAllowed)
            }
            Section("Sécurité et vie privée") {
                Toggle("Mode HTTPS uniquement (met à niveau http:// et avertit avant de continuer)", isOn: $model.httpsOnly)
                Toggle("Retirer les paramètres de suivi des liens (utm_*, fbclid, gclid…)", isOn: $model.urlCleaning)
                Toggle("Réduire le fingerprinting (canvas, WebGL, audio)", isOn: $model.fingerprintProtection)
                Button("Mettre à jour les listes de filtres maintenant") { model.onUpdateFilterLists() }
            }
            Section("Navigation sécurisée Google (Safe Browsing)") {
                Toggle("Activer (désactivé par défaut)", isOn: $model.safeBrowsingEnabled)
                SecureField("Clé d'API Google Safe Browsing", text: $model.safeBrowsingKey)
                Text("Les préfixes de hachage (4 octets) des adresses suspectes sont envoyés à Google pour confirmation ; les autres adresses ne quittent jamais votre Mac. Nécessite votre propre clé d'API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Autorisations des sites") {
                if model.storedPermissions.isEmpty {
                    Text("Aucune autorisation mémorisée. Par défaut, les choix caméra, micro et position sont oubliés à la fermeture.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.storedPermissions, id: \.self.origin) { item in
                    HStack {
                        Text("\(item.origin) — \(item.permission.rawValue) : \(item.decision.rawValue)")
                        Spacer()
                        Button("Oublier") { model.resetPermission(item) }
                    }
                }
                Button("Actualiser") { model.reloadPermissions() }
            }
    }

    @ViewBuilder private var passwordSections: some View {
            Section("Mots de passe") {
                if model.savedLogins.isEmpty {
                    Text("Aucun mot de passe enregistré. Orée proposera d'en enregistrer à la connexion.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.savedLogins) { login in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(login.username.isEmpty ? "(sans identifiant)" : login.username)
                            Text(login.origin).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Copier") { model.copyPassword(of: login) }
                        Button("Supprimer", role: .destructive) { model.deleteLogin(login) }
                    }
                }
                TextField("Site", text: $model.newLoginSite, prompt: Text("exemple.com"))
                TextField("Identifiant", text: $model.newLoginUser, prompt: Text("nom ou e-mail"))
                SecureField("Mot de passe", text: $model.newLoginPassword, prompt: Text("mot de passe"))
                Button("Ajouter") { model.addLogin() }
                Button("Importer un fichier CSV (Mots de passe Apple, Chrome…)") { model.importPasswordCSV() }
                if let message = model.passwordMessage {
                    Text(message).font(.caption)
                }
                Text("Chiffrés (ChaChaPoly) avec une clé stockée dans le Trousseau ; copie et remplissage protégés par Touch ID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    }

    @ViewBuilder private var dataSections: some View {
            Section("Données de navigation") {
                Button("Effacer l'historique", role: .destructive) { model.pendingDestructiveAction = .clearHistory }
                Button("Effacer cookies et données de site", role: .destructive) { model.pendingDestructiveAction = .clearCookies }
                Button("Effacer les favoris", role: .destructive) { model.pendingDestructiveAction = .clearBookmarks }
            }
            if model.braveCookiesAvailable {
                Section("Cookies de Brave") {
                    Button(model.cookieImportRunning ? "Import en cours…" : "Importer les cookies de Brave…") { model.importBraveCookies() }
                        .disabled(model.cookieImportRunning)
                    Text("Reste connecté aux mêmes sites. Demande votre autorisation (Trousseau macOS) et ne sort jamais de ce Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let message = model.cookieImportMessage { Text(message).font(.caption) }
                }
            }
            Section("Importer depuis un autre navigateur") {
                let detected = model.detectedBrowsers()
                if detected.isEmpty {
                    Text("Aucun autre navigateur pris en charge détecté.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(detected, id: \.self) { browser in
                        Button("Importer depuis \(browser.displayName)") { model.importBookmarks(from: browser) }
                    }
                    Text("Favoris uniquement (pas l'historique, pas les mots de passe).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let message = model.importResultMessage {
                    Text(message).font(.caption)
                }
            }
        
    }

    @ViewBuilder private var advancedSections: some View {
            Section("Développeurs") {
                Toggle("Activer l'inspecteur web (clic droit > Inspecter l'élément)", isOn: $model.webInspectorEnabled)
            }
    }

    @ViewBuilder private var extensionsSections: some View {
        Section("Extensions installées") {
            if model.installedExtensions.isEmpty {
                Text("Aucune extension. Ajoutez un dossier, un .zip ou un .crx d'extension (format Chrome ou Safari, manifest v2/v3).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.installedExtensions) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name + (item.version.isEmpty ? "" : "  v\(item.version)"))
                        if !item.summary.isEmpty {
                            Text(item.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { item.isEnabled }, set: { model.setExtension(item.id, enabled: $0) }))
                        .labelsHidden()
                    Button("Supprimer", role: .destructive) { model.removeExtension(item.id) }
                }
            }
            Button("Ajouter une extension…") { model.addExtension() }
                .disabled(!model.canManageExtensions)
            if let message = model.extensionMessage {
                Text(message).font(.caption)
            }
            Text("Chaque extension ne voit que les sites et fonctions que vous lui avez autorisés à l'installation. Elles sont désactivées en navigation privée.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Réglages")
                .font(.custom("InstrumentSerif-Italic", size: 32))
                .foregroundStyle(OreeColor.text)
                .padding(.leading, 10).padding(.bottom, 12).padding(.top, 4)
            ForEach(SettingsCategory.allCases) { category in
                Button {
                    model.category = category
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: category.symbol).frame(width: 18)
                        Text(category.title)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(model.category == category ? OreeColor.raised : Color.clear)
                    )
                    .foregroundStyle(model.category == category ? OreeColor.text : OreeColor.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(category.title)
                .accessibilityAddTraits(model.category == category ? .isSelected : [])
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 214)
        .background(OreeColor.chrome)
    }

    private func perform(_ action: SettingsViewModel.DestructiveAction) {
        switch action {
        case .clearHistory: model.clearHistory()
        case .clearCookies: model.clearCookies()
        case .clearBookmarks: model.clearBookmarks()
        }
    }
}

/// Orée tokens as adaptive SwiftUI colors (follow light/dark automatically).
enum OreeColor {
    static func dynamic(_ token: DualColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = token.resolved(dark: dark)
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
        })
    }
    static var chrome: Color { dynamic(OreeTokens.chrome) }
    static var raised: Color { dynamic(OreeTokens.raised) }
    static var text: Color { dynamic(OreeTokens.text) }
    static var muted: Color { dynamic(OreeTokens.muted) }
    static var field: Color { dynamic(OreeTokens.field) }
    static var accent: Color { dynamic(SettingsStore.shared.accentHue.solid) }
}


// MARK: - Shortcuts editor

/// Lists every editable command with its shortcut; "Modifier" records the next key combination.
@MainActor
final class ShortcutsModel: ObservableObject {
    @Published var overrides: [String: KeyBinding] = SettingsStore.shared.shortcutOverrides
    @Published var recordingID: String?
    @Published var message: String?
    private var monitor: Any?

    var resolved: [String: KeyBinding] { ShortcutRegistry.resolve(overrides: overrides) }

    func startRecording(_ id: String) {
        stopRecording()
        recordingID = id
        message = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let code = event.keyCode, flags = event.modifierFlags.rawValue
            let characters = event.charactersIgnoringModifiers
            let consumed = MainActor.assumeIsolated { self.handle(keyCode: code, flags: NSEvent.ModifierFlags(rawValue: flags), characters: characters) }
            return consumed ? nil : event
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingID = nil
    }

    private func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> Bool {
        guard let id = recordingID else { return false }
        if keyCode == 53 { stopRecording(); return true }                 // Escape cancels
        if keyCode == 51 { set(id, KeyBinding("", [])); stopRecording(); return true }   // Delete clears
        var mods: ShortcutModifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        guard let key = characters?.lowercased(), !key.isEmpty else { return true }
        let binding = KeyBinding(key, mods)
        if !binding.isUsable { message = "Ajoutez au moins ⌘, ⌃ ou ⌥ à la touche."; return true }
        if ShortcutRegistry.isReserved(binding) { message = "\(binding.display) est réservé par le système ou par les onglets."; return true }
        if let other = ShortcutRegistry.conflict(for: binding, excluding: id, in: resolved) {
            message = "\(binding.display) est déjà utilisé par « \(other.title) »."
            return true
        }
        set(id, binding)
        stopRecording()
        return true
    }

    private func set(_ id: String, _ binding: KeyBinding) {
        let isDefault = ShortcutRegistry.commands.first { $0.id == id }?.defaultBinding == binding
        if isDefault { overrides[id] = nil } else { overrides[id] = binding }
        SettingsStore.shared.shortcutOverrides = overrides
        message = nil
    }

    func reset(_ id: String) {
        overrides[id] = nil
        SettingsStore.shared.shortcutOverrides = overrides
    }

    func resetAll() {
        overrides = [:]
        SettingsStore.shared.shortcutOverrides = [:]
    }
}

struct ShortcutsSection: View {
    @StateObject private var model = ShortcutsModel()

    var body: some View {
        Section {
            Text("Cliquez sur « Modifier », puis tapez la nouvelle combinaison. Échap annule, Supprimer retire le raccourci.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(Color.red)
            }
        }
        ForEach(sections, id: \.self) { section in
            Section(section) {
                ForEach(ShortcutRegistry.commands.filter { $0.section == section }) { command in
                    row(command)
                }
            }
        }
        Section {
            Button("Rétablir tous les raccourcis") { model.resetAll() }
                .disabled(model.overrides.isEmpty)
        }
    }

    private var sections: [String] {
        var seen: [String] = []
        for c in ShortcutRegistry.commands where !seen.contains(c.section) { seen.append(c.section) }
        return seen
    }

    @ViewBuilder private func row(_ command: ShortcutCommand) -> some View {
        let recording = model.recordingID == command.id
        HStack(spacing: 8) {
            Text(command.title)
            Spacer()
            if recording {
                Text("Tapez une combinaison…").font(.caption.weight(.semibold)).foregroundStyle(OreeColor.accent)
            } else if let binding = model.resolved[command.id] {
                Text(binding.display)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(OreeColor.field))
                    .accessibilityLabel("Raccourci \(binding.display)")
            } else {
                Text("Aucun").font(.caption).foregroundStyle(.secondary)
            }
            if model.overrides[command.id] != nil, !recording {
                Button("Rétablir") { model.reset(command.id) }.buttonStyle(.borderless)
            }
            Button(recording ? "Annuler" : "Modifier") {
                recording ? model.stopRecording() : model.startRecording(command.id)
            }
        }
    }
}


// MARK: - Appearance, layout, downloads

/// "Apparence": opens the customization drawer and manages saved configurations.
@MainActor
final class AppearanceModel: ObservableObject {
    @Published var saved = SettingsStore.shared.savedLookProfiles
    @Published var newName = ""
    @Published var refresh = 0
}

struct AppearanceSection: View {
    let onOpenCustomize: () -> Void
    @StateObject private var model = AppearanceModel()

    var body: some View {
        Section {
            Text("Thème, couleur d’accent, densité, arrondi et page d’accueil se règlent dans le centre de personnalisation, qui s’applique en direct.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Ouvrir le centre de personnalisation…") { onOpenCustomize() }
        }
        Section("Configurations") {
            ForEach(LookProfile.builtIn) { profile in row(profile, deletable: false) }
            ForEach(model.saved) { profile in row(profile, deletable: true) }
            HStack {
                TextField("Nom de la configuration", text: $model.newName)
                Button("Enregistrer l’actuelle") {
                    let name = model.newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    var all = model.saved.filter { $0.name != name }
                    all.append(LookProfile.capture(named: String(name.prefix(24)), from: SettingsStore.shared))
                    model.saved = all
                    SettingsStore.shared.savedLookProfiles = all
                    model.newName = ""
                }
                .disabled(model.newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .id(model.refresh)
    }

    private func row(_ profile: LookProfile, deletable: Bool) -> some View {
        let current = LookProfile.capture(named: profile.name, from: SettingsStore.shared).sameLook(as: profile)
        return HStack {
            Circle().fill(OreeColor.dynamic(profile.accent.solid)).frame(width: 12, height: 12)
            Text(profile.name)
            if current { Text("actuelle").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("Appliquer") { profile.apply(to: SettingsStore.shared); model.refresh += 1 }.disabled(current)
            if deletable {
                Button("Supprimer") {
                    model.saved.removeAll { $0.name == profile.name }
                    SettingsStore.shared.savedLookProfiles = model.saved
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

/// "Disposition": where tabs live and how the sidebar behaves.
@MainActor
final class LayoutModel: ObservableObject { @Published var refresh = 0 }

struct LayoutSection: View {
    @StateObject private var model = LayoutModel()
    private var store: SettingsStore { SettingsStore.shared }

    private func picker<T: Hashable>(_ title: String, _ options: [(String, T)], get: @escaping () -> T, set: @escaping (T) -> Void) -> some View {
        Picker(title, selection: Binding(get: get, set: { set($0); model.refresh += 1 })) {
            ForEach(options.indices, id: \.self) { Text(options[$0].0).tag(options[$0].1) }
        }
        .pickerStyle(.segmented)
    }

    var body: some View {
        Section("Onglets") {
            picker("Emplacement", TabLayout.allCases.map { ($0.label, $0) }, get: { store.tabLayout }, set: { store.tabLayout = $0 })
            picker("Barre latérale", SidebarMode.allCases.map { ($0.label, $0) }, get: { store.sidebarMode }, set: { store.sidebarMode = $0 })
            HStack {
                Text("Largeur")
                Slider(value: Binding(get: { store.sidebarWidth }, set: { store.sidebarWidth = $0; model.refresh += 1 }),
                       in: SidebarWidth.minimum...SidebarWidth.maximum, step: 2)
                Text("\(Int(store.sidebarWidth)) pt").font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                Button("Rétablir") { store.sidebarWidth = SidebarWidth.standard; model.refresh += 1 }.buttonStyle(.borderless)
            }
            Toggle("Effet verre (Liquid Glass) en mode « Au survol »",
                   isOn: Binding(get: { store.sidebarGlass }, set: { store.sidebarGlass = $0; model.refresh += 1 }))
            Text("« Au survol » : la barre est cachée et apparaît par-dessus la page quand le pointeur touche le bord gauche. Vous pouvez aussi tirer le bord de la barre pour la redimensionner. Sous 900 px de large, la barre fixe passe en mode compact toute seule.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Lignes et texte") {
            picker("Densité", OreeTokens.Density.allCases.map { ($0.label, $0) }, get: { store.density }, set: { store.density = $0 })
            picker("Taille du texte de l’interface", [("Petit", -1), ("Moyen", 0), ("Grand", 1)], get: { store.uiTextOffset }, set: { store.uiTextOffset = $0 })
            Toggle("Réduire les animations", isOn: Binding(get: { store.calmMotion }, set: { store.calmMotion = $0; model.refresh += 1 }))
            Text("N’affecte pas le zoom des pages. Suit aussi le réglage « Réduire les animations » de macOS.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .id(model.refresh)
    }
}

@MainActor
final class DownloadsSettingsModel: ObservableObject {
    private let store = SettingsStore.shared
    @Published var maxConnections: Int { didSet { store.downloadMaxConnections = maxConnections } }
    @Published var adaptive: Bool { didSet { store.downloadAdaptive = adaptive } }
    @Published var mirrors: Bool { didSet { store.downloadMirrors = mirrors } }
    @Published var yieldToBrowsing: Bool { didSet { store.downloadYieldToBrowsing = yieldToBrowsing } }
    init() {
        let s = SettingsStore.shared
        maxConnections = s.downloadMaxConnections; adaptive = s.downloadAdaptive; mirrors = s.downloadMirrors; yieldToBrowsing = s.downloadYieldToBrowsing
    }
}

/// "Téléchargements": where files go and how fast / how politely they are fetched.
struct DownloadsSection: View {
    @StateObject private var model = DownloadsSettingsModel()
    private var folder: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first! }

    var body: some View {
        Section("Destination") {
            LabeledContent("Dossier") { Text(folder.path).foregroundStyle(.secondary).textSelection(.enabled) }
            Button("Afficher dans le Finder") { NSWorkspace.shared.open(folder) }
        }
        Section("Vitesse") {
            Stepper(value: $model.maxConnections, in: 1...16) {
                LabeledContent("Connexions maximum par fichier") { Text("\(model.maxConnections)").foregroundStyle(.secondary) }
            }
            Toggle("Adapter le nombre de connexions au débit", isOn: $model.adaptive)
            Toggle("Utiliser les serveurs miroirs que le site annonce", isOn: $model.mirrors)
            Text("Orée démarre avec quelques connexions et en ajoute tant que chacune apporte au moins 10 % de vitesse en plus ; si le serveur dit stop (erreurs 429/503), il en retire. Les miroirs ne reçoivent jamais vos cookies.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Navigation") {
            Toggle("Laisser la priorité aux pages web pendant leur chargement", isOn: $model.yieldToBrowsing)
            Text("Les téléchargements ralentissent le temps qu’une page se charge, puis retrouvent leur vitesse.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Text("Les téléchargements tournent dans un processus séparé : ils continuent si vous quittez Orée. Les fichiers sont marqués par macOS (quarantaine) et un téléchargement interrompu reprend où il s’était arrêté.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
