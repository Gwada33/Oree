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
    case general, appearance, layout, privacy, assistant, passwords, shortcuts, downloads, extensions, data, advanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "Général"
        case .privacy: return "Confidentialité"
        case .assistant: return "Assistant IA"
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
        case .assistant: return "sparkles"
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
    @Published var customShortcuts: [SearchShortcut] = []
    @Published var newShortcutName = ""
    @Published var newShortcutKeyword = ""
    @Published var newShortcutTemplate = ""
    @Published var shortcutMessage: String?
    @Published var downloadDirectory = ""
    @Published var tabPreviews = true { didSet { settings.tabPreviews = tabPreviews } }
    @Published var tabArchiveDays = 0 { didSet { settings.tabArchiveDays = tabArchiveDays } }
    @Published var mouseGestures = false { didSet { settings.mouseGestures = mouseGestures } }
    @Published var autoRejectCookies = true { didSet { settings.autoRejectCookieBanners = autoRejectCookies } }
    @Published var spotlight = false { didSet { settings.spotlightIndexing = spotlight; NotificationCenter.default.post(name: Notification.Name("Oree.settingsChanged"), object: nil) } }
    @Published var eventJournal = false { didSet { settings.eventJournalEnabled = eventJournal; refreshJournalStatus() } }
    @Published var eventJournalDays = 30 { didSet { settings.eventJournalDays = eventJournalDays } }
    @Published var journalStatus = ""
    @Published var energyMode: EnergyMode = .automatic { didSet { settings.energyMode = energyMode } }
    @Published var sendGPC = true { didSet { settings.sendGlobalPrivacyControl = sendGPC } }
    @Published var minimumFontSize = 0 { didSet { settings.minimumFontSize = minimumFontSize } }
    @Published var clearHistoryOnQuit = false { didSet { settings.clearHistoryOnQuit = clearHistoryOnQuit } }
    @Published var clearSiteDataOnQuit = false { didSet { settings.clearSiteDataOnQuit = clearSiteDataOnQuit } }
    @Published var userAgentMode: UserAgentMode = .safari { didSet { settings.userAgentMode = userAgentMode } }
    @Published var customUserAgent = "" { didSet { settings.customUserAgent = customUserAgent } }
    @Published var chromeAgentHosts: [String] = []
    @Published var newChromeAgentHost = ""

    func addChromeAgentHost() {
        let host = newChromeAgentHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "").components(separatedBy: "/").first ?? ""
        guard !host.isEmpty, host.contains("."), !chromeAgentHosts.contains(host) else { return }
        chromeAgentHosts.append(host)
        settings.chromeUserAgentHosts = chromeAgentHosts
        newChromeAgentHost = ""
    }

    func removeChromeAgentHost(_ host: String) {
        chromeAgentHosts.removeAll { $0 == host }
        settings.chromeUserAgentHosts = chromeAgentHosts
    }

    var newShortcut: SearchShortcut { SearchShortcut(name: newShortcutName, keyword: newShortcutKeyword.lowercased(), template: newShortcutTemplate) }

    func addShortcut() {
        let shortcut = newShortcut
        guard shortcut.isValid else { shortcutMessage = "Il faut un nom, un mot-clé court sans espace, et une adresse http(s) qui contient %s."; return }
        if customShortcuts.contains(where: { $0.keyword == shortcut.keyword }) { shortcutMessage = "Ce mot-clé existe déjà."; return }
        customShortcuts.append(shortcut)
        settings.customSearchShortcuts = customShortcuts
        newShortcutName = ""; newShortcutKeyword = ""; newShortcutTemplate = ""; shortcutMessage = nil
    }

    func removeShortcut(_ keyword: String) {
        customShortcuts.removeAll { $0.keyword == keyword }
        settings.customSearchShortcuts = customShortcuts
    }

    func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Choisir"; panel.message = "Dossier où enregistrer les téléchargements"
        if panel.runModal() == .OK, let url = panel.url { downloadDirectory = url.path; settings.downloadDirectoryPath = url.path }
    }

    func resetDownloadFolder() { downloadDirectory = ""; settings.downloadDirectoryPath = "" }
    @Published var homepageURL: String {
        didSet { settings.customHomepageURL = homepageURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    @Published var adBlockEnabled: Bool { didSet { settings.adBlockEnabled = adBlockEnabled } }
    @Published var privateByDefault: Bool { didSet { settings.privateByDefault = privateByDefault } }
    @Published var calmModeEverywhere: Bool { didSet { settings.calmModeEverywhere = calmModeEverywhere } }
    @Published var digestAutoRecipes: Bool { didSet { settings.digestAutoRecipes = digestAutoRecipes } }
    @Published var resumeEnabled: Bool { didSet { settings.resumeEnabled = resumeEnabled } }
    @Published var cleanCopy: Bool { didSet { settings.cleanCopy = cleanCopy } }
    @Published var copyAddsSource: Bool { didSet { settings.copyAddsSource = copyAddsSource } }
    @Published var nightMode: NightMode { didSet { settings.nightMode = nightMode } }
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
    private let resumeRepo = ResumeRepository()
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
    @Published var passwordReport: [String] = []
    @Published var addresses: [AddressProfile] = []
    @Published var cards: [CardProfile] = []
    @Published var editingAddress: AddressProfile?
    @Published var editingCard: CardProfile?
    let autofill = AutofillStore()
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
        customShortcuts = current.customSearchShortcuts
        downloadDirectory = current.downloadDirectoryPath
        tabPreviews = current.tabPreviews
        tabArchiveDays = current.tabArchiveDays
        spotlight = current.spotlightIndexing
        autoRejectCookies = current.autoRejectCookieBanners
        mouseGestures = current.mouseGestures
        eventJournal = current.eventJournalEnabled
        eventJournalDays = current.eventJournalDays
        energyMode = current.energyMode
        sendGPC = current.sendGlobalPrivacyControl
        minimumFontSize = current.minimumFontSize
        clearHistoryOnQuit = current.clearHistoryOnQuit
        clearSiteDataOnQuit = current.clearSiteDataOnQuit
        userAgentMode = current.userAgentMode
        customUserAgent = current.customUserAgent
        chromeAgentHosts = current.chromeUserAgentHosts
        homepageURL = current.customHomepageURL
        adBlockEnabled = current.adBlockEnabled
        privateByDefault = current.privateByDefault
        calmModeEverywhere = current.calmModeEverywhere
        digestAutoRecipes = current.digestAutoRecipes
        resumeEnabled = current.resumeEnabled
        cleanCopy = current.cleanCopy
        copyAddsSource = current.copyAddsSource
        autoplayAllowed = current.autoplayMediaAllowed
        nightMode = current.nightMode
        autoSuspendMinutes = current.autoSuspendMinutes
        freezeAfterSeconds = current.freezeAfterSeconds
        reloadPermissions()
        reloadLogins(); reloadAutofill()
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
        NotificationCenter.default.post(name: Notification.Name("Oree.historyCleared"), object: nil)
        try? resumeRepo.clear()          // where the user was in each page is part of what they browsed
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
                case .assistant: AssistantSection()
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
        // Clic droit sur un bouton › « Personnaliser les barres… » : la fenêtre s'ouvre sur « Disposition ».
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("Oree.selectSettingsCategory"))) { note in
            if let raw = note.object as? String, let c = SettingsCategory(rawValue: raw) { model.category = c }
        }
        .frame(minWidth: 760, minHeight: 560)
        .sheet(item: $model.editingAddress) { address in AddressEditor(address: address, onSave: { model.saveAddress($0) }, onCancel: { model.editingAddress = nil }) }
        .sheet(item: $model.editingCard) { card in CardEditor(card: card, onSave: { model.saveCard($0) }, onCancel: { model.editingCard = nil }) }
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
                Text("Raccourcis : tape un mot-clé, un espace, puis ta recherche dans la barre d’adresse. Ex. « w Lisbonne », « yt chats », « gh swift », « so crash », « maps Paris », « ddg », « b », « br », « q ».")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.customShortcuts) { shortcut in
                    HStack {
                        Text("\(shortcut.keyword)").font(.system(.body, design: .monospaced)).frame(width: 70, alignment: .leading)
                        Text(shortcut.name)
                        Spacer()
                        Text(shortcut.template).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button(role: .destructive) { model.removeShortcut(shortcut.keyword) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Nom", text: $model.newShortcutName).frame(width: 110)
                    TextField("Mot-clé", text: $model.newShortcutKeyword).frame(width: 80)
                    TextField("https://site.exemple/?q=%s", text: $model.newShortcutTemplate)
                    Button("Ajouter") { model.addShortcut() }
                }
                if let message = model.shortcutMessage { Text(message).font(.caption).foregroundStyle(.red) }
            }
            Section("Identité du navigateur") {
                Picker("Se présenter aux sites comme", selection: $model.userAgentMode) {
                    ForEach(UserAgentMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if model.userAgentMode == .custom {
                    TextField("Texte du user-agent", text: $model.customUserAgent)
                    if !model.customUserAgent.isEmpty && !UserAgent.isAcceptableCustom(model.customUserAgent) {
                        Text("Une seule ligne, en caractères ASCII, 300 au plus : sinon Safari est utilisé.").font(.caption).foregroundStyle(.red)
                    }
                }
                if model.userAgentMode == .safari {
                    ForEach(model.chromeAgentHosts, id: \.self) { host in
                        HStack {
                            Text(host)
                            Spacer()
                            Text("vu comme Chrome").font(.caption).foregroundStyle(.secondary)
                            Button(role: .destructive) { model.removeChromeAgentHost(host) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("site.exemple (vu comme Chrome)", text: $model.newChromeAgentHost)
                        Button("Ajouter") { model.addChromeAgentHost() }
                    }
                }
                Text("Safari convient presque partout. Certains sites refusent un navigateur qu’ils ne connaissent pas : présente-toi comme Chrome pour eux seulement (aussi dans la palette ⌘K, « Se présenter comme Chrome sur ce site »).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Onglets") {
                Toggle("Aperçu d’un onglet quand le pointeur s’y arrête", isOn: $model.tabPreviews)
                Text("Une image de la page, son titre et la mémoire qu’elle prend (ou « En veille »). Jamais pour l’onglet affiché.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Archiver les onglets inutilisés", selection: $model.tabArchiveDays) {
                    Text("Jamais").tag(0)
                    Text("Après 1 jour").tag(1)
                    Text("Après 7 jours").tag(7)
                    Text("Après 30 jours").tag(30)
                }
                Text("Un onglet archivé se ferme mais reste dans la liste « Onglets archivés » (palette ⌘K), où un clic le rouvre. Pas les onglets privés, ni celui qui joue du son.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Énergie") {
                Picker("Mode économie d’énergie", selection: $model.energyMode) {
                    ForEach(EnergyMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("Quand il est actif, les onglets que tu ne regardes pas sont figés et mis en veille deux fois plus tôt : moins de processeur, plus d’autonomie.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Confidentialité") {
                Toggle("Demander aux sites de ne pas vendre ni partager mes données (Global Privacy Control)", isOn: $model.sendGPC)
                Text("Les sites peuvent lire ce signal ; ceux qui le respectent (c’est une obligation légale dans plusieurs régions) cessent de te suivre. Il n’est pas ajouté aux requêtes elles-mêmes.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Effacer l’historique en quittant Orée", isOn: $model.clearHistoryOnQuit)
                Toggle("Effacer les cookies et les données des sites en quittant Orée", isOn: $model.clearSiteDataOnQuit)
                Text("Les favoris, les mots de passe enregistrés et les onglets ouverts ne sont jamais effacés. Effacer les cookies te déconnecte des sites.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Texte des pages") {
                Picker("Taille de texte minimale", selection: $model.minimumFontSize) {
                    Text("Celle de la page").tag(0)
                    ForEach([9, 10, 12, 14, 16, 18, 20], id: \.self) { Text("\($0) points").tag($0) }
                }
                Text("Agrandit les textes que des sites écrivent trop petits. S’applique aux pages ouvertes comme aux suivantes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Téléchargements") {
                HStack {
                    Text(model.downloadDirectory.isEmpty ? "Dossier Téléchargements du Mac" : model.downloadDirectory).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choisir…") { model.chooseDownloadFolder() }
                    if !model.downloadDirectory.isEmpty { Button("Par défaut") { model.resetDownloadFolder() } }
                }
                Text("S’applique aux prochains téléchargements.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Mode nuit des sites") {
                Picker("Assombrir les sites", selection: $model.nightMode) {
                    Text("Jamais").tag(NightMode.off)
                    Text("Automatique (quand Orée est en mode sombre)").tag(NightMode.auto)
                    Text("Toujours").tag(NightMode.always)
                }
                Text("Les sites qui ont déjà un thème sombre ne sont pas touchés. Une icône en forme de lune dans la barre d'outils laisse un site clair d'un clic. Orée suit l'apparence du Mac : le réglage Night Shift n'est pas accessible aux applications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Section("Gestes de souris") {
                Toggle("Gestes avec le bouton droit (maintenir, tracer, relâcher)", isOn: $model.mouseGestures)
                Text("← page précédente · → page suivante · ↓ nouvel onglet · ↓→ fermer l'onglet · ↑↓ recharger · ↑ haut de la page · ↓↑ bas de la page · ↑← onglet précédent · ↑→ onglet suivant · ↓← rouvrir l'onglet fermé. Un clic droit sans tracer ouvre le menu comme d'habitude. Désactivé par défaut.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Spotlight") {
                Toggle("Retrouver mes favoris et mon historique récent dans la recherche Spotlight", isOn: $model.spotlight)
                Text("Seuls le titre et le site (pas le contenu des pages) sont donnés à Spotlight : 300 pages récentes et tous les favoris. Rien en navigation privée. Effacer l'historique les retire aussi, et couper ce réglage vide l'index.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Journal d’événements") {
                Toggle("Garder un journal de la façon dont j’utilise Orée, sur ce Mac", isOn: $model.eventJournal)
                Text("Pour mesurer et régler la vitesse d’Orée avec des chiffres réels : onglets ouverts, choisis ou mis en veille, temps de chargement, liens survolés et cliqués, déplacements du pointeur et défilement (résumés par petites fenêtres), barre d’adresse (nombre de touches, suggestion choisie). Jamais l’adresse ni le titre d’une page, jamais ce que vous tapez ou les touches, jamais rien en navigation privée ni sur une page de mot de passe : les sites ne sont que des empreintes propres à ce Mac. Chiffré, jamais envoyé. S’applique aux pages (re)chargées après l’activation.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.eventJournal {
                    Picker("Durée de garde", selection: $model.eventJournalDays) {
                        Text("7 jours").tag(7); Text("30 jours").tag(30); Text("90 jours").tag(90)
                    }
                }
                if !model.journalStatus.isEmpty { Text(model.journalStatus).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Exporter…") { model.exportJournal() }
                    Button("Effacer le journal", role: .destructive) { model.clearJournal() }
                    Button("Actualiser") { model.refreshJournalStatus() }
                }
            }
            Section("Confidentialité") {
                Toggle("Bloquer les publicités et traqueurs", isOn: $model.adBlockEnabled)
                Toggle("Ouvrir les nouveaux onglets en navigation privée par défaut", isOn: $model.privateByDefault)
                Toggle("Autoriser la lecture automatique des vidéos et sons", isOn: $model.autoplayAllowed)
                Toggle("Refuser automatiquement les bannières de cookies", isOn: $model.autoRejectCookies)
                Text("Orée clique sur « Tout refuser » (ou « Continuer sans accepter ») des gestionnaires de consentement courants. Jamais sur « Accepter » : s'il n'y a pas de bouton de refus clair, la bannière reste. S'applique aux pages chargées ensuite\(SettingsStore.shared.cookieBannersRejected > 0 ? " · \(SettingsStore.shared.cookieBannersRejected) bannière(s) refusée(s) jusqu'ici" : "").")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Mode calme et personnalisation des sites") {
                Toggle("Mode calme sur tous les sites (sans lecture automatique, sans animations, sans pastilles de notification)", isOn: $model.calmModeEverywhere)
                Text("⌘K › « Personnaliser ce site… » : décrivez en une phrase ce que vous voulez changer sur le site ouvert (par exemple « cache les recommandations et agrandis le texte »). Le modèle local écrit des règles de style, jamais de script ; elles sont vérifiées, gardées pour ce site seulement, et « Annuler » les retire aussitôt. Nécessite macOS 26 et Apple Intelligence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("L'essentiel") {
                Toggle("Ouvrir directement l'essentiel sur les pages de recette qui le fournissent (instantané, sans IA)", isOn: $model.digestAutoRecipes)
                Text("Le bouton de la barre d'outils (ou ⌘K › « L'essentiel ») résume n'importe quelle page avec le modèle local d'Apple Intelligence : environ 30 secondes, nécessite macOS 26 et Apple Intelligence, peut contenir des erreurs. Rien ne quitte le Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Reprise") {
                Toggle("Proposer de reprendre une vidéo ou un article là où je m'étais arrêté", isOn: $model.resumeEnabled)
                Text("Positions gardées sur ce Mac seulement (90 jours), jamais en navigation privée, effacées avec les données de navigation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Copier-coller") {
                Toggle("Copier proprement (sans la police, les couleurs ni les liens du site ; les tableaux restent des tableaux)", isOn: $model.cleanCopy)
                Toggle("Ajouter la source aux citations copiées, avec un lien vers le passage", isOn: $model.copyAddsSource)
                    .disabled(!model.cleanCopy)
                Text("S'applique aux pages ouvertes après le changement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Section("Adresses et cartes (remplissage automatique)") {
                if model.addresses.isEmpty && model.cards.isEmpty {
                    Text("Aucune adresse ni carte. Orée proposera de les enregistrer quand vous remplirez un formulaire, ou ajoutez-les ici.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.addresses) { address in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(address.label.isEmpty ? address.fullName : address.label)
                            Text([address.fullName, address.summary].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Modifier") { model.editingAddress = address }
                        Button("Supprimer", role: .destructive) { model.deleteAutofill(address.id) }
                    }
                }
                ForEach(model.cards) { card in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(card.label.isEmpty ? card.brand : card.label)
                            Text(card.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Modifier") { model.editCard(card) }
                        Button("Supprimer", role: .destructive) { model.deleteAutofill(card.id) }
                    }
                }
                HStack {
                    Button("Ajouter une adresse…") { model.editingAddress = AddressProfile() }
                    Button("Ajouter une carte…") { model.editingCard = CardProfile() }
                }
                Text("Chiffrées sur ce Mac (clé dans le Trousseau). Les cartes ne se remplissent qu'après Touch ID, et leur code de sécurité n'est jamais enregistré.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                        Menu("2FA") {
                            if model.hasTOTP(login) {
                                Button("Copier le code") { model.copyCode(of: login) }
                                Button("Retirer le code 2FA", role: .destructive) { model.removeTOTP(of: login) }
                            } else {
                                Button("Ajouter un code 2FA…") { model.addTOTP(to: login) }
                            }
                        }
                        .fixedSize()
                        Button("Copier") { model.copyPassword(of: login) }
                        Button("Supprimer", role: .destructive) { model.deleteLogin(login) }
                    }
                }
                TextField("Site", text: $model.newLoginSite, prompt: Text("exemple.com"))
                TextField("Identifiant", text: $model.newLoginUser, prompt: Text("nom ou e-mail"))
                SecureField("Mot de passe", text: $model.newLoginPassword, prompt: Text("mot de passe"))
                Button("Ajouter") { model.addLogin() }
                Button("Importer un fichier CSV (Mots de passe Apple, Chrome…)") { model.importPasswordCSV() }
                Button("Exporter en CSV…") { model.exportPasswordCSV() }
                Button("Vérifier mes mots de passe (fuites, réutilisation, faiblesse)") { model.auditPasswords() }
                ForEach(model.passwordReport, id: \.self) { Text($0).font(.caption) }
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
        ChromeLayoutSection()
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


/// Le profil que l'assistant peut utiliser pour remplir des formulaires, via des jetons `{{profil.prenom}}`… Gardé dans le Trousseau, jamais
/// envoyé au modèle (le navigateur remplace le jeton au moment du geste, et seulement après votre accord pour un envoi).
@MainActor
final class AssistantProfileModel: ObservableObject {
    static let fields: [(key: String, label: String)] = [
        ("prenom", "Prénom"), ("nom", "Nom"), ("email", "Adresse e-mail"), ("telephone", "Téléphone"),
        ("adresse", "Adresse"), ("code_postal", "Code postal"), ("ville", "Ville"), ("pays", "Pays"),
    ]
    private let keychain = ProfileKeychain()
    @Published var values: [String: String]
    @Published var saved = false
    init() { values = keychain.load() }
    func binding(_ key: String) -> Binding<String> {
        Binding(get: { self.values[key] ?? "" }, set: { self.values[key] = $0; self.saved = false })
    }
    func save() {
        values = values.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        saved = keychain.save(values)
    }
}

@MainActor
final class AssistantProviderModel: ObservableObject {
    @Published var provider: AIProvider { didSet { SettingsStore.shared.aiProviderChoice = provider; model = SettingsStore.shared.aiModel(for: provider); hasKey = CloudKeychain(provider).hasKey; keyDraft = ""; if provider == .lmstudio { refreshModels() } } }
    @Published var model: String { didSet { if provider.usesAPI { SettingsStore.shared.setAIModel(model, for: provider) } } }
    @Published var keyDraft = ""
    @Published var tick = 0                 // relance l'affichage après un réglage écrit hors du modèle
    @Published var hasKey: Bool
    // LM Studio : adresse du serveur local et modèles qu'il propose.
    @Published var lmURL = SettingsStore.shared.lmStudioBaseText { didSet { SettingsStore.shared.setLMStudioBase(text: lmURL) } }
    @Published var lmModels: [String] = []
    @Published var lmStatus = ""
    func refreshModels() {
        lmStatus = "Recherche des modèles…"
        let base = SettingsStore.shared.lmStudioBase
        Task { @MainActor in
            var request = URLRequest(url: LMStudio.modelsURL(base: base), timeoutInterval: 3)
            request.httpMethod = "GET"
            if let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 {
                lmModels = LMStudio.parseModels(data)
                lmStatus = lmModels.isEmpty ? "Le serveur répond mais aucun modèle de conversation n'est chargé." : "\(lmModels.count) modèle\(lmModels.count > 1 ? "s" : "") trouvé\(lmModels.count > 1 ? "s" : "") sur \(base.host ?? "le serveur")."
                if !lmModels.contains(model) { model = lmModels.first ?? "" }
            } else {
                lmModels = []
                lmStatus = "LM Studio ne répond pas sur \(base.absoluteString). Lancez-le et démarrez le serveur local (Developer › Start Server)."
            }
        }
    }
    init() {
        let keys = Set(AIProvider.allCases.filter { $0.isCloud && CloudKeychain($0).hasKey })
        let current = AIProvider.effective(stored: SettingsStore.shared.aiProviderChoice, keys: keys)
        provider = current
        hasKey = keys.contains(current)
        model = SettingsStore.shared.aiModel(for: current)
    }
    func saveKey() { let keychain = CloudKeychain(provider); if keychain.save(keyDraft) { keyDraft = ""; hasKey = keychain.hasKey } }
    func removeKey() { CloudKeychain(provider).delete(); hasKey = false }
}

struct AssistantSection: View {
    @StateObject private var profile = AssistantProfileModel()
    @StateObject private var provider = AssistantProviderModel()

    var body: some View {
        Section("Cerveau de l'assistant") {
            Picker("Fournisseur", selection: $provider.provider) {
                ForEach(AIProvider.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.menu)
            if provider.provider == .lmstudio {
                TextField("Adresse du serveur", text: $provider.lmURL, prompt: Text("http://localhost:1234/v1"))
                    .onSubmit { provider.refreshModels() }
                HStack {
                    Picker("Modèle", selection: $provider.model) {
                        if !provider.lmModels.contains(provider.model) { Text(provider.model.isEmpty ? "Choisir…" : provider.model).tag(provider.model) }
                        ForEach(provider.lmModels, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Actualiser") { provider.refreshModels() }
                }
                if !provider.lmStatus.isEmpty { Text(provider.lmStatus).font(.caption).foregroundStyle(.secondary) }
                Text("LM Studio prête à Orée les modèles que vous avez téléchargés chez lui : lancez son serveur local (onglet Developer), chargez un modèle, puis actualisez. Avec l'adresse par défaut (localhost), rien ne quitte votre Mac. Choisissez un modèle qui sait appeler des outils (par exemple gpt-oss ou Qwen) : sans cela, Luciole répond en texte mais n'agit pas.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if provider.provider.isCloud {
                TextField("Modèle \(provider.provider.displayName)", text: $provider.model)
                HStack {
                    SecureField(provider.hasKey ? "Clé enregistrée (collez-en une autre pour la remplacer)" : "Clé API \(provider.provider.displayName)", text: $provider.keyDraft)
                    Button("Enregistrer") { provider.saveKey() }.disabled(provider.keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if provider.hasKey { Button("Retirer") { provider.removeKey() } }
                }
                Text("Avec \(provider.provider.displayName), l'assistant appelle de vrais outils et répond bien plus vite, mais le texte de la page que vous lui demandez de lire (titres, libellés des champs, extraits) et vos questions sont envoyés à \(provider.provider.displayName), dans le nuage. Les valeurs de votre profil, elles, restent sur ce Mac : seuls les jetons {{profil.xxx}} sont envoyés. La clé est gardée dans le Trousseau.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("Mémoire de Luciole") {
            Toggle("Garder les discussions et un journal de ce que Luciole a fait", isOn: Binding(get: { SettingsStore.shared.lucioleMemoryEnabled }, set: { SettingsStore.shared.lucioleMemoryEnabled = $0; provider.tick += 1 }))
            Text("Luciole peut ainsi rouvrir une discussion, et se souvenir de ce qu'elle a fait sur un site ou de ce que vous lui avez appris (par exemple votre prénom, si elle vous l'a demandé). Tout reste dans un fichier de ce Mac. Les valeurs saisies dans les formulaires ne sont jamais gardées, ni rien en navigation privée.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Effacer la mémoire de Luciole", role: .destructive) { LucioleMemory.erase(); provider.tick += 1 }
        }
        .id(provider.tick)
        Section("Profil pour l'assistant") {
            ForEach(AssistantProfileModel.fields, id: \.key) { field in
                TextField(field.label, text: profile.binding(field.key))
            }
            HStack {
                Button("Enregistrer") { profile.save() }
                if profile.saved { Text("Enregistré dans le Trousseau.").font(.caption).foregroundStyle(.secondary) }
            }
            Text("Quand vous demandez « remplis ce formulaire », l'assistant écrit des jetons comme {{profil.prenom}} ; Orée met la vraie valeur dans la page. Le modèle ne voit jamais ces valeurs. Il ne remplit jamais un mot de passe ni une carte, et demande toujours votre accord avant d'envoyer un formulaire, de payer ou de télécharger.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}


/// La disposition des boutons : où est chaque bouton (barre d'outils à gauche / à droite, bas de la barre latérale, masqué), dans quel ordre,
/// quelle taille. Les changements s'appliquent tout de suite dans la fenêtre.
@MainActor
final class ChromeLayoutModel: ObservableObject {
    @Published var layout = SettingsStore.shared.chromeLayout
    func commit() { SettingsStore.shared.chromeLayout = layout; layout = SettingsStore.shared.chromeLayout }
    func reload() { layout = SettingsStore.shared.chromeLayout }
    func move(_ item: ChromeItem, by delta: Int) {
        let zone = layout.zone(of: item)
        guard let index = layout.items(in: zone).firstIndex(of: item) else { return }
        layout.move(item, to: zone, at: index + delta)
        commit()
    }
    func send(_ item: ChromeItem, to zone: ChromeZone) { layout.move(item, to: zone); commit() }
    func setPinned(_ item: ChromeItem, _ on: Bool) { if on { layout.pinned.insert(item) } else { layout.pinned.remove(item) }; commit() }
    func reset() { layout = .standard; commit() }
}

struct ChromeLayoutSection: View {
    @StateObject private var model = ChromeLayoutModel()

    private func row(_ item: ChromeItem, zone: ChromeZone, index: Int, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.symbol).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                if item.isContextual {
                    Toggle("Toujours à sa place (grisé quand il ne sert pas)", isOn: Binding(get: { model.layout.pinned.contains(item) }, set: { model.setPinned(item, $0) }))
                        .toggleStyle(.checkbox).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { model.move(item, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(index == 0).help("Monter").accessibilityLabel("Monter \(item.title)")
            Button { model.move(item, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(index == count - 1).help("Descendre").accessibilityLabel("Descendre \(item.title)")
            Menu {
                ForEach(ChromeZone.allCases.filter { $0 != zone && !(item.isRequired && $0 == .hidden) }, id: \.self) { target in
                    Button(target.title) { model.send(item, to: target) }
                }
            } label: { Image(systemName: "arrow.left.arrow.right") }
                .menuStyle(.borderlessButton).frame(width: 30).help("Déplacer vers…").accessibilityLabel("Déplacer \(item.title) vers…")
        }
    }

    var body: some View {
        Section("Boutons : barre d'outils et barre latérale") {
            Picker("Taille des icônes", selection: Binding(get: { model.layout.iconSize }, set: { model.layout.iconSize = $0; model.commit() })) {
                ForEach(ChromeIconSize.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Toggle("Afficher « Rechercher, aller à… » dans la barre latérale", isOn: Binding(get: { model.layout.showSearchRow }, set: { model.layout.showSearchRow = $0; model.commit() }))
            Toggle("Afficher « Nouvel onglet » dans la barre latérale", isOn: Binding(get: { model.layout.showNewTabRow }, set: { model.layout.showNewTabRow = $0; model.commit() }))
            Text("Clic droit sur un bouton de la fenêtre : le masquer ou le déplacer sans venir ici. La palette de commandes (⌘K) reste toujours visible : c'est votre chemin de retour.")
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(ChromeZone.allCases, id: \.self) { zone in
            Section(zone.title) {
                let items = model.layout.items(in: zone)
                if items.isEmpty { Text("Aucun bouton").foregroundStyle(.secondary) }
                ForEach(Array(items.enumerated()), id: \.element) { index, item in row(item, zone: zone, index: index, count: items.count) }
            }
        }
        Section {
            Button("Rétablir la disposition d'origine") { model.reset() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            if model.layout != SettingsStore.shared.chromeLayout { model.reload() }
        }
    }
}

// MARK: - Journal d'événements (statut, export, effacement)
extension SettingsViewModel {
    func refreshJournalStatus() {
        guard eventJournal else { journalStatus = ""; return }
        let stats = JournalControls.stats()
        guard stats.events > 0 else { journalStatus = "Rien d’enregistré pour l’instant."; return }
        let size = ByteCountFormatter.string(fromByteCount: stats.bytes, countStyle: .file)
        let since = stats.first.map { " depuis le " + $0.formatted(.dateTime.day().month(.wide).hour().minute().locale(Locale(identifier: "fr_FR"))) } ?? ""
        journalStatus = "\(stats.events) événements · \(size) sur disque\(since)."
    }

    func exportJournal() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "journal-oree-\(Date().formatted(.iso8601.year().month().day())).jsonl"
        panel.message = "Le fichier exporté n’est pas chiffré : il contient des empreintes de sites et des durées, mais pas d’adresse ni de texte."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let count = try JournalControls.export(url); journalStatus = "\(count) événements exportés dans \(url.lastPathComponent)." }
        catch { journalStatus = "Export impossible : \(error.localizedDescription)" }
    }

    func clearJournal() {
        let alert = NSAlert()
        alert.messageText = "Effacer tout le journal ?"
        alert.informativeText = "Les événements gardés sur ce Mac seront supprimés. Cela ne touche ni l’historique ni les onglets."
        alert.addButton(withTitle: "Effacer"); alert.addButton(withTitle: "Annuler")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        JournalControls.clear()
        refreshJournalStatus()
    }
}

// MARK: - Mots de passe : 2FA, export, santé
extension SettingsViewModel {
    func hasTOTP(_ login: SavedLogin) -> Bool { vault.hasTOTP(origin: login.origin, username: login.username) }

    func addTOTP(to login: SavedLogin) {
        let alert = NSAlert()
        alert.messageText = "Code 2FA pour « \(login.username.isEmpty ? login.origin : login.username) »"
        alert.informativeText = "Collez la clé secrète que le site vous a montrée (« JBSW Y3DP… ») ou l'adresse otpauth:// du code QR. Orée calcule alors les codes à 6 chiffres, sur ce Mac."
        alert.addButton(withTitle: "Enregistrer"); alert.addButton(withTitle: "Annuler")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); field.placeholderString = "clé secrète ou otpauth://…"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let config = TOTPConfig.parse(field.stringValue) else { passwordMessage = "Cette clé n'est pas lisible (base32 ou adresse otpauth://totp attendue)."; return }
        do { try vault.saveTOTP(config, origin: login.origin, username: login.username); passwordMessage = "Code 2FA enregistré : par exemple \(config.code()) en ce moment."; objectWillChange.send() }
        catch { passwordMessage = "Enregistrement impossible : \(error.localizedDescription)" }
    }

    func removeTOTP(of login: SavedLogin) {
        try? vault.deleteTOTP(origin: login.origin, username: login.username)
        passwordMessage = "Code 2FA retiré."; objectWillChange.send()
    }

    func copyCode(of login: SavedLogin) {
        Task {
            guard await VaultUnlocker.shared.authenticate(reason: "Copier le code 2FA de \(login.username)"),
                  let config = try? vault.totp(origin: login.origin, username: login.username) else { passwordMessage = "Authentification refusée ou code illisible."; return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents(); pasteboard.setString(config.code(), forType: .string)
            let count = pasteboard.changeCount
            passwordMessage = "Code copié (valable encore \(config.secondsRemaining()) s)."
            try? await Task.sleep(for: .seconds(30))
            if pasteboard.changeCount == count { pasteboard.clearContents() }
        }
    }

    /// Exporte tous les mots de passe (et leurs codes 2FA) en CSV, EN CLAIR : après Touch ID, et un avertissement.
    func exportPasswordCSV() {
        Task {
            guard await VaultUnlocker.shared.authenticate(reason: "Exporter tous les mots de passe") else { passwordMessage = "Authentification refusée."; return }
            let alert = NSAlert()
            alert.messageText = "Exporter les mots de passe en clair ?"
            alert.informativeText = "Le fichier contiendra tous vos mots de passe sans chiffrement. Gardez-le le moins longtemps possible et supprimez-le après usage."
            alert.addButton(withTitle: "Exporter…"); alert.addButton(withTitle: "Annuler")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "mots-de-passe-oree.csv"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                let rows = try vault.everything().map { PasswordCSVExporter.Row(url: $0.origin, username: $0.username, password: $0.password, otpAuth: $0.totp.map(Self.otpURI) ?? "") }
                try PasswordCSVExporter.csv(rows).write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                passwordMessage = "\(rows.count) mot(s) de passe exporté(s) dans \(url.lastPathComponent)."
            } catch { passwordMessage = "Export impossible : \(error.localizedDescription)" }
        }
    }

    static func otpURI(_ config: TOTPConfig) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out = "", buffer = 0, bits = 0
        for byte in config.secret { buffer = (buffer << 8) | Int(byte); bits += 8; while bits >= 5 { bits -= 5; out.append(alphabet[(buffer >> bits) & 31]) } }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        var uri = "otpauth://totp/\(config.account ?? "compte")?secret=\(out)&digits=\(config.digits)&period=\(config.period)&algorithm=\(config.algorithm.rawValue)"
        if let issuer = config.issuer { uri += "&issuer=\(issuer.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? issuer)" }
        return uri
    }

    /// Fuites (5 caractères d'empreinte envoyés par mot de passe, jamais le mot de passe), réutilisation, faiblesse. Touch ID d'abord.
    func auditPasswords() {
        Task {
            guard await VaultUnlocker.shared.authenticate(reason: "Vérifier la santé des mots de passe") else { passwordMessage = "Authentification refusée."; return }
            passwordMessage = "Vérification en cours…"; passwordReport = []
            let items = ((try? vault.everything()) ?? []).map { PasswordAudit.Item(origin: $0.origin, username: $0.username, password: $0.password) }
            var breaches: [String: Int] = [:], networkFailed = false
            var ranges: [String: String] = [:]      // un seul appel par préfixe
            for password in Set(items.map(\.password)) where !password.isEmpty {
                let parts = PasswordAudit.pwnedParts(of: password)
                if ranges[parts.prefix] == nil, let url = PasswordAudit.pwnedURL(prefix: parts.prefix) {
                    var request = URLRequest(url: url, timeoutInterval: 10)
                    request.setValue("true", forHTTPHeaderField: "Add-Padding")      // la taille de la réponse ne renseigne pas sur la fuite
                    if let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 { ranges[parts.prefix] = String(decoding: data, as: UTF8.self) }
                    else { networkFailed = true }
                }
                if let body = ranges[parts.prefix] { breaches[password] = PasswordAudit.pwnedCount(in: body, suffix: parts.suffix) }
            }
            let report = PasswordAudit.analyze(items, breaches: breaches)
            var lines: [String] = []
            if report.isClean && !networkFailed { lines.append("Rien à signaler sur \(report.checked) compte(s).") }
            for (account, count) in report.breached.sorted(by: { $0.key < $1.key }) { lines.append("⚠︎ Mot de passe vu \(count) fois dans des fuites : \(account)") }
            for group in report.reused { lines.append("Même mot de passe sur plusieurs comptes : " + group.joined(separator: " · ")) }
            for account in report.weak { lines.append("Mot de passe faible : \(account)") }
            if networkFailed { lines.append("Les fuites n'ont pas pu être vérifiées (pas de réseau ?) : le reste est calculé sur ce Mac.") }
            passwordReport = lines
            passwordMessage = "Vérification terminée."
        }
    }
}

// MARK: - Adresses et cartes
extension SettingsViewModel {
    func reloadAutofill() {
        addresses = (try? autofill.addresses()) ?? []
        cards = (try? autofill.cards()) ?? []
    }

    func saveAddress(_ address: AddressProfile) {
        var saved = address
        if saved.label.trimmingCharacters(in: .whitespaces).isEmpty { saved.label = saved.city.isEmpty ? (saved.fullName.isEmpty ? "Adresse" : saved.fullName) : saved.city }
        try? autofill.save(saved); editingAddress = nil; reloadAutofill()
    }

    func saveCard(_ card: CardProfile) {
        var saved = card
        saved.number = CardTools.digits(saved.number)
        if saved.label.trimmingCharacters(in: .whitespaces).isEmpty { saved.label = saved.brand }
        try? autofill.save(saved); editingCard = nil; reloadAutofill()
    }

    /// Modifier une carte montre son numéro en clair : Touch ID d'abord.
    func editCard(_ card: CardProfile) {
        Task {
            guard await VaultUnlocker.shared.authenticate(reason: "Modifier la carte \(card.masked)") else { passwordMessage = "Authentification refusée."; return }
            editingCard = card
        }
    }

    func deleteAutofill(_ id: UUID) { try? autofill.delete(id: id); reloadAutofill() }
}

final class AddressDraft: ObservableObject {
    @Published var address: AddressProfile
    init(_ address: AddressProfile) { self.address = address }
}

struct AddressEditor: View {
    @StateObject private var draft: AddressDraft
    let onSave: (AddressProfile) -> Void
    let onCancel: () -> Void
    init(address: AddressProfile, onSave: @escaping (AddressProfile) -> Void, onCancel: @escaping () -> Void) {
        _draft = StateObject(wrappedValue: AddressDraft(address)); self.onSave = onSave; self.onCancel = onCancel
    }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Nom de l'adresse", text: $draft.address.label, prompt: Text("Maison, Travail…"))
                Section {
                    TextField("Prénom", text: $draft.address.firstName); TextField("Nom", text: $draft.address.lastName)
                    TextField("Société", text: $draft.address.organization)
                    TextField("E-mail", text: $draft.address.email); TextField("Téléphone", text: $draft.address.phone)
                }
                Section {
                    TextField("Adresse", text: $draft.address.street); TextField("Complément", text: $draft.address.street2)
                    TextField("Code postal", text: $draft.address.postalCode); TextField("Ville", text: $draft.address.city)
                    TextField("Région", text: $draft.address.region); TextField("Pays", text: $draft.address.country)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Annuler", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Enregistrer") { onSave(draft.address) }.keyboardShortcut(.defaultAction).disabled(draft.address.isEmpty)
            }.padding()
        }
        .frame(width: 440, height: 560)
    }
}

final class CardDraft: ObservableObject {
    @Published var card: CardProfile
    @Published var number: String
    @Published var expiry: String
    init(_ card: CardProfile) {
        self.card = card
        number = CardTools.grouped(card.number)
        expiry = card.expMonth > 0 ? String(format: "%02d/%02d", card.expMonth, card.expYear % 100) : ""
    }
    var parsedExpiry: (month: Int, year: Int)? { CardTools.parseExpiry(expiry) }
    var problem: String? {
        if !number.isEmpty, !CardTools.isValid(number) { return "Ce numéro ne passe pas le contrôle (faute de frappe ?)." }
        if !expiry.isEmpty, parsedExpiry == nil { return "Date d'expiration illisible (08/27)." }
        if let e = parsedExpiry, CardTools.isExpired(month: e.month, year: e.year) { return "Cette carte est expirée." }
        return nil
    }
}

struct CardEditor: View {
    @StateObject private var draft: CardDraft
    let onSave: (CardProfile) -> Void
    let onCancel: () -> Void
    init(card: CardProfile, onSave: @escaping (CardProfile) -> Void, onCancel: @escaping () -> Void) {
        _draft = StateObject(wrappedValue: CardDraft(card)); self.onSave = onSave; self.onCancel = onCancel
    }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Nom de la carte", text: $draft.card.label, prompt: Text("Perso, Pro…"))
                TextField("Titulaire", text: $draft.card.holder)
                TextField("Numéro", text: $draft.number).onChange(of: draft.number) { _, new in
                    let grouped = CardTools.grouped(new); if grouped != new { draft.number = grouped }
                }
                TextField("Expiration", text: $draft.expiry, prompt: Text("MM/AA"))
                if let problem = draft.problem { Text(problem).font(.caption).foregroundStyle(.red) }
                Text("Le code de sécurité (CVC) n'est jamais enregistré : vous le tapez à chaque achat.").font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Annuler", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Enregistrer") {
                    var saved = draft.card; saved.number = draft.number
                    if let e = draft.parsedExpiry { saved.expMonth = e.month; saved.expYear = e.year }
                    onSave(saved)
                }.keyboardShortcut(.defaultAction).disabled(!CardTools.isValid(draft.number) || draft.problem != nil)
            }.padding()
        }
        .frame(width: 440, height: 360)
    }
}
