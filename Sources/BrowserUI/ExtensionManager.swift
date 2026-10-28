import AppKit
import WebKit
import BrowserCore

/// Owns the browser's extensions: installs/removes them, loads them at launch, answers the
/// engine's requests (open a tab, ask for a permission, show a popup) and keeps the toolbar
/// buttons up to date. The engine does the heavy lifting (`WKWebExtensionController`); this is
/// the glue between it and our tabs and windows.
@MainActor
final class ExtensionManager: NSObject, ExtensionsProviding, WKWebExtensionControllerDelegate {
    private struct Record: Codable {
        var id: String
        var directory: String   // relative to `root`
        var enabled: Bool
    }

    let controller: WKWebExtensionController
    weak var windowController: BrowserWindowController? { didSet { bridge.window = windowController; bridge.manager = self } }
    let bridge = ExtensionBridge()
    /// Permissions du manifeste d'ORIGINE de chaque extension chargée (par identifiant de contexte).
    private var originalPermissions: [String: Set<String>] = [:]
    /// Called whenever the set of extensions or an action (icon, badge) changes.
    var onChange: (() -> Void)?
    /// The automation channel can't click a permission dialog.
    var autoApprove = false

    private var records: [Record] = []
    private var contexts: [String: WKWebExtensionContext] = [:]
    private let root: URL
    private var recordsFile: URL { root.appendingPathComponent("extensions.json") }

    override init() {
        let base = ProcessInfo.processInfo.environment["HB_EXT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HyperBrowser/Extensions", isDirectory: true)
        root = base
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A fixed identifier makes the engine keep each extension's storage between launches.
        // Un identifiant fixe fait garder à WebKit le stockage de chaque extension entre deux lancements. Les essais en prennent un à eux (HB_EXT_CONTROLLER_ID) pour ne pas écrire dans celui de l'app.
        let controllerID = ProcessInfo.processInfo.environment["HB_EXT_CONTROLLER_ID"].flatMap(UUID.init(uuidString:)) ?? UUID(uuidString: "6E7A9C52-4B1D-4F3A-9D0E-48A5B6C7D8E9")!
        let configuration = WKWebExtensionController.Configuration(identifier: controllerID)
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
        bridge.permissions = { [weak self] context in self?.originalPermissions[context.uniqueIdentifier] ?? [] }
        if let data = try? Data(contentsOf: recordsFile), let saved = try? JSONDecoder().decode([Record].self, from: data) {
            records = saved
        }
    }

    var hasEnabledExtensions: Bool { records.contains { $0.enabled } }

    // MARK: Loading

    private var windowRegistered = false
    private var keyMonitor: Any?
    /// Les raccourcis que les extensions déclarent (`commands` du manifeste) : WebKit sait quelle extension répond à quelle touche, l'app doit lui passer les frappes.
    /// Les raccourcis d'Orée (menus) passent avant, comme dans Chrome.
    private func installCommandMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let e = event
            return mainActorNow {
                guard let self, !self.contexts.isEmpty else { return e }
                if Self.menuHandles(e) { self.bridge.note("raccourci : pris par un menu d'Orée (\(e.charactersIgnoringModifiers ?? "?"))"); return e }
                for context in self.contexts.values where context.performCommand(for: e) { self.bridge.note("raccourci : exécuté pour \(context.webExtension.displayName ?? "?")"); return nil }
                self.bridge.note("raccourci : aucune extension (\(e.charactersIgnoringModifiers ?? "?") \(e.modifierFlags.rawValue))")
                return e
            }
        }
    }
    private static func menuHandles(_ event: NSEvent) -> Bool {
        let wanted = event.modifierFlags.intersection([.command, .shift, .option, .control]), key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        func search(_ menu: NSMenu) -> Bool {
            menu.items.contains { item in
                (!item.keyEquivalent.isEmpty && item.keyEquivalent.lowercased() == key && item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == wanted) || (item.submenu.map(search) ?? false)
            }
        }
        return NSApp.mainMenu.map(search) ?? false
    }
    /// Le moteur doit connaître la fenêtre (et ses onglets) : sans cela, « clic sur le bouton d'une extension » pour un onglet ne fait rien.
    private func registerWindowIfNeeded() {
        guard !windowRegistered, let windowController else { return }
        windowRegistered = true
        installCommandMonitor()
        controller.didOpenWindow(windowController)
        controller.didFocusWindow(windowController)
        for tab in windowController.extensionTabs { controller.didOpenTab(tab) }
        if let active = windowController.activeExtensionTab { controller.didActivateTab(active, previousActiveTab: nil); controller.didSelectTabs([active]) }
    }

    func loadAll() async {
        registerWindowIfNeeded()
        installCommandMonitor()
        for index in records.indices where records[index].enabled { await load(adoptingChromeID(at: index)) }
        onChange?()
    }

    /// Une extension qui a une `key` reçoit l'identifiant que Chrome lui donne (chrome.runtime.id, adresse de ses pages…) : les services externes (connexion OAuth)
    /// la reconnaissent ainsi. Un enregistrement plus ancien, qui avait un identifiant au hasard, est renommé une fois pour toutes.
    private func adoptingChromeID(at index: Int) -> Record {
        let record = records[index]
        let directory = root.appendingPathComponent(record.directory, isDirectory: true)
        Self.applyCompat(to: directory)
        guard let chromeID = ExtensionCompat.chromeID(at: directory), chromeID != record.id, !records.contains(where: { $0.id == chromeID }) else { return record }
        records[index].id = chromeID
        save()
        return records[index]
    }

    private func load(_ record: Record) async {
        let directory = root.appendingPathComponent(record.directory, isDirectory: true)
        do {
            Self.applyCompat(to: directory)
            let webExtension = try await WKWebExtension(resourceBaseURL: directory)
            let context = WKWebExtensionContext(for: webExtension)
            context.uniqueIdentifier = record.id
            // The user approved these when installing.
            for permission in webExtension.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
            for pattern in webExtension.allRequestedMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
            originalPermissions[record.id] = Self.manifestPermissions(at: directory)
            try controller.load(context)
            contexts[record.id] = context
            // Le fond (service worker) ne se charge qu'à la demande ; on le démarre tout de suite pour que le premier clic sur le bouton ait une page qui l'écoute.
            // (la version `async` de loadBackgroundContent plante quand WebKit appelle deux fois son rappel : on utilise le rappel directement)
            if webExtension.hasBackgroundContent {
                let name = webExtension.displayName ?? "?"
                bridge.note("fond : chargement demandé (\(name))")
                context.loadBackgroundContent { [weak self] error in
                    nonisolated(unsafe) let message = error?.localizedDescription
                    mainActorNow { self?.bridge.note(message.map { "fond : ERREUR \($0)" } ?? "fond : chargé") }
                }
            }
        } catch {
            Log.tabs.error("Could not load extension \(record.id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Le script de compatibilité (API chrome.* que WebKit n'a pas) est ajouté à la copie de l'extension avant son chargement.
    private static func applyCompat(to directory: URL) {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("ExtCompat", isDirectory: true),
              let core = try? String(contentsOf: folder.appendingPathComponent("core.js"), encoding: .utf8) else { return }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("sections").path)) ?? []).filter { $0.hasSuffix(".js") }.sorted().filter { name in !(ProcessInfo.processInfo.environment["HB_COMPAT_SKIP"] ?? "").split(separator: ",").contains { name.hasPrefix($0) } }
        let sections = names.compactMap { try? String(contentsOf: folder.appendingPathComponent("sections/\($0)"), encoding: .utf8) }
        do { try ExtensionCompat.apply(to: directory, shim: Data(ExtensionCompat.assemble(core: core, sections: sections).utf8), backgroundAsPage: ProcessInfo.processInfo.environment["HB_BACKGROUND_SW"] == nil) }
        catch { Log.tabs.error("Compatibilité des extensions : \(String(describing: error), privacy: .public)") }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: recordsFile, options: .atomic) }
    }

    // MARK: ExtensionsProviding

    func installedExtensions() -> [ExtensionInfo] {
        records.map { record in
            let context = contexts[record.id]
            let webExtension = context?.webExtension
            return ExtensionInfo(
                id: record.id,
                name: webExtension?.displayName ?? Self.manifestName(at: root.appendingPathComponent(record.directory)) ?? "Extension",
                version: webExtension?.displayVersion ?? "",
                summary: webExtension?.displayDescription ?? "",
                isEnabled: record.enabled,
                hasOptions: context?.optionsPageURL != nil
            )
        }
    }

    /// L'extension vue par chrome.management.
    func managementInfo(id: String) -> [String: Any]? {
        guard let record = records.first(where: { $0.id == id }) else { return nil }
        let dir = root.appendingPathComponent(record.directory)
        let original = dir.appendingPathComponent("__oree/manifest.orig.json")
        let file = FileManager.default.fileExists(atPath: original.path) ? original : dir.appendingPathComponent("manifest.json")
        let json = ((try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let permissions = (json["permissions"] as? [String]) ?? []
        let hosts = ((json["host_permissions"] as? [String]) ?? []) + permissions.filter { $0.contains("://") || $0 == "<all_urls>" }
        let context = contexts[id]
        var info: [String: Any] = ["id": id, "name": context?.webExtension.displayName ?? (json["name"] as? String) ?? "Extension", "shortName": (json["short_name"] as? String) ?? (json["name"] as? String) ?? "",
            "description": (json["description"] as? String) ?? "", "version": (json["version"] as? String) ?? "", "mayDisable": true, "enabled": record.enabled, "isApp": false, "type": "extension", "installType": "normal",
            "offlineEnabled": false, "permissions": permissions.filter { !$0.contains("://") && $0 != "<all_urls>" }, "hostPermissions": hosts, "icons": [Any](), "disabledReason": record.enabled ? "" : "unknown"]
        if let home = json["homepage_url"] as? String { info["homepageUrl"] = home }
        if let url = context?.optionsPageURL { info["optionsUrl"] = url.absoluteString }
        return info
    }

    func allManagementInfo() -> [[String: Any]] { records.compactMap { managementInfo(id: $0.id) } }

    /// `permissions` et `optional_permissions` du manifeste d'origine (avant notre modification).
    static func manifestPermissions(at directory: URL) -> Set<String> {
        let original = directory.appendingPathComponent("__oree/manifest.orig.json")
        let file = FileManager.default.fileExists(atPath: original.path) ? original : directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: file), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return Set((json["permissions"] as? [String] ?? []) + (json["optional_permissions"] as? [String] ?? []))
    }

    private static func manifestName(at directory: URL) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return json["name"] as? String
    }

    func install(from url: URL) async throws {
        registerWindowIfNeeded()
        let folderName = UUID().uuidString
        let destination = root.appendingPathComponent(folderName, isDirectory: true)
        let unpacked: URL
        do {
            unpacked = try ExtensionPackage.unpack(url, to: destination)
            let webExtension = try await WKWebExtension(resourceBaseURL: unpacked)
            guard await approveInstall(of: webExtension, manifestPermissions: Self.manifestPermissions(at: unpacked)) else { throw CancellationError() }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        let relative = String(unpacked.path.dropFirst(root.path.count + 1))
        Self.applyCompat(to: unpacked)
        let id = ExtensionCompat.chromeID(at: unpacked) ?? folderName
        if records.contains(where: { $0.id == id }) { remove(id: id) }         // réinstaller remplace
        let record = Record(id: id, directory: relative, enabled: true)
        records.append(record)
        save()
        await load(record)
        onChange?()
        if let info = managementInfo(id: id) { bridge.broadcast("management.onInstalled", info) }
        if let windowController { for tab in windowController.extensionTabs { controller.didOpenTab(tab) } }      // le nouveau contexte doit connaître les onglets déjà ouverts
    }

    func setEnabled(_ enabled: Bool, id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].enabled != enabled else { return }
        records[index].enabled = enabled
        save()
        defer { if let info = managementInfo(id: id) { bridge.broadcast(enabled ? "management.onEnabled" : "management.onDisabled", info) } }
        if enabled {
            let record = records[index]
            Task { await load(record); onChange?() }
        } else if let context = contexts.removeValue(forKey: id) {
            bridge.unload(id)
            try? controller.unload(context)
            onChange?()
        }
    }

    func remove(id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        if let context = contexts.removeValue(forKey: id) { bridge.unload(id); try? controller.unload(context) }
        let record = records.remove(at: index)
        save()
        bridge.broadcast("management.onUninstalled", id)
        // The record's directory is "<id>" or "<id>/<top folder>"; remove the whole <id> directory.
        try? FileManager.default.removeItem(at: root.appendingPathComponent(String(record.directory.split(separator: "/").first ?? Substring(record.id))))
        onChange?()
    }

    // MARK: Permission dialogs

    private static let permissionNames: [String: String] = [
        "tabs": "Voir l'adresse et le titre de vos onglets", "activeTab": "Accéder à l'onglet sur lequel vous cliquez",
        "storage": "Enregistrer ses propres données", "cookies": "Lire et modifier vos cookies",
        "history": "Lire votre historique", "bookmarks": "Lire et modifier vos favoris",
        "downloads": "Gérer vos téléchargements", "webNavigation": "Suivre la navigation dans vos onglets",
        "webRequest": "Observer les requêtes réseau", "declarativeNetRequest": "Bloquer ou modifier des requêtes réseau",
        "scripting": "Exécuter des scripts dans les pages", "contextMenus": "Ajouter des éléments au menu contextuel",
        "clipboardRead": "Lire le presse-papiers", "clipboardWrite": "Écrire dans le presse-papiers",
        "nativeMessaging": "Communiquer avec une application de votre Mac", "notifications": "Afficher des notifications",
        "alarms": "Programmer des tâches", "unlimitedStorage": "Utiliser un stockage illimité",
        "topSites": "Voir vos sites les plus visités", "sessions": "Voir vos onglets récemment fermés", "readingList": "Lire et modifier votre liste de lecture",
        "management": "Voir et gérer les extensions installées", "idle": "Savoir si vous utilisez l'ordinateur", "power": "Empêcher la mise en veille",
        "system.cpu": "Voir les informations du processeur", "system.memory": "Voir la mémoire de l'ordinateur", "system.storage": "Voir les disques", "system.display": "Voir les écrans",
        "browsingData": "Effacer vos données de navigation", "search": "Lancer des recherches", "tts": "Lire du texte à voix haute",
        "debugger": "CONTRÔLER LES PAGES À DISTANCE (clics, saisie, lecture du contenu) : accès très large", "sidePanel": "Afficher un panneau latéral", "offscreen": "Ouvrir des pages cachées en arrière-plan",
        "identity": "Vous connecter à des comptes", "proxy": "Modifier le proxy du navigateur", "tabGroups": "Gérer les groupes d'onglets", "privacy": "Lire et modifier des réglages de confidentialité",
        "contentSettings": "Modifier les autorisations des sites", "webRequestBlocking": "Bloquer ou modifier des requêtes réseau", "declarativeNetRequestWithHostAccess": "Bloquer ou modifier des requêtes réseau",
        "declarativeContent": "Agir selon le contenu des pages", "tabCapture": "Capturer l'audio et la vidéo d'un onglet", "desktopCapture": "Capturer l'écran", "pageCapture": "Enregistrer une page",
        "geolocation": "Connaître votre position", "gcm": "Recevoir des messages push", "favicon": "Lire les icônes des sites", "fontSettings": "Modifier les polices", "commands": "Définir des raccourcis clavier",
    ]

    private func describe(_ webExtension: WKWebExtension, manifestPermissions: Set<String> = []) -> String {
        // WebKit ne connaît que 14 permissions : les autres (history, debugger…) viennent du manifeste, et ne doivent pas rester cachées.
        let names = Set(webExtension.requestedPermissions.map(\.rawValue)).union(manifestPermissions)
        var lines = names.map { Self.permissionNames[$0] ?? "Permission « \($0) »" }.sorted()
        let patterns = webExtension.allRequestedMatchPatterns.map(\.string).sorted()
        if patterns.contains(where: { $0 == "<all_urls>" || $0.hasPrefix("*://*/") }) {
            lines.append("Lire et modifier TOUTES les pages que vous visitez")
        } else if !patterns.isEmpty {
            lines.append("Lire et modifier les pages de : " + patterns.prefix(4).joined(separator: ", ") + (patterns.count > 4 ? "…" : ""))
        }
        return lines.isEmpty ? "Aucune permission particulière." : lines.map { "• \($0)" }.joined(separator: "\n")
    }

    private func approveInstall(of webExtension: WKWebExtension, manifestPermissions: Set<String> = []) async -> Bool {
        if autoApprove { return true }
        guard let window = windowController?.window else { return false }
        let alert = NSAlert()
        alert.messageText = "Installer « \(webExtension.displayName ?? "cette extension") » ?"
        alert.informativeText = "Cette extension pourra :\n\n\(describe(webExtension, manifestPermissions: manifestPermissions))"
        alert.addButton(withTitle: "Installer")
        alert.addButton(withTitle: "Annuler")
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    private func ask(_ title: String, detail: String, completion: @escaping (Bool) -> Void) {
        guard !autoApprove, let window = windowController?.window else { completion(autoApprove); return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Autoriser")
        alert.addButton(withTitle: "Refuser")
        alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
    }

    // MARK: Events from our tabs

    func tabOpened(_ tab: Tab) { if windowRegistered, !tab.isPrivate { controller.didOpenTab(tab) } }
    func tabClosed(_ tab: Tab) { if windowRegistered, !tab.isPrivate { controller.didCloseTab(tab, windowIsClosing: false) } }
    func tabActivated(_ tab: Tab, previous: Tab?) {
        guard windowRegistered, !tab.isPrivate else { return }
        controller.didActivateTab(tab, previousActiveTab: (previous?.isPrivate == false) ? previous : nil)
        controller.didSelectTabs([tab])
    }
    func tabChanged(_ tab: Tab, _ properties: WKWebExtension.TabChangedProperties) {
        if windowRegistered, !tab.isPrivate { controller.didChangeTabProperties(properties, for: tab) }
    }

    // MARK: Toolbar

    /// One entry per loaded extension that has an action (toolbar button).
    func toolbarEntries(for tab: Tab?) -> [(id: String, context: WKWebExtensionContext, action: WKWebExtension.Action)] {
        records.compactMap { record in
            guard let context = contexts[record.id], let action = context.action(for: tab) else { return nil }
            return (record.id, context, action)
        }
    }

    /// Ouvre la page de réglages de l'extension dans un onglet (ou dit qu'elle n'en a pas).
    @discardableResult
    func openOptions(id: String) -> Bool {
        guard let context = contexts[id], let url = context.optionsPageURL, let windowController else { return false }
        windowController.newTab(extensionPage: url, context: context)
        return true
    }

    /// Une adresse chrome-extension://<id>/… (la redirection d'une connexion OAuth vers l'extension) devient la page de l'extension, dans un onglet à part.
    func openChromeExtensionURL(_ url: URL, closing tab: Tab?) -> Bool {
        guard ["chrome-extension", "moz-extension"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased(),
              let context = contexts.values.first(where: { $0.uniqueIdentifier.lowercased() == host }), let windowController else { return false }
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query { path += "?" + query }
        if let fragment = url.fragment { path += "#" + fragment }
        guard let target = URL(string: path, relativeTo: context.baseURL)?.absoluteURL else { return false }
        windowController.newTab(extensionPage: target, context: context)
        if let tab { Task { @MainActor [weak windowController] in windowController?.closeTab(tab, remember: false) } }
        return true
    }

    func performAction(id: String, for tab: Tab?) {
        let state = contexts[id]?.action(for: tab)
        bridge.note("clic sur le bouton de \(contexts[id]?.webExtension.displayName ?? id) : actif=\(state?.isEnabled ?? false) popup=\(state?.presentsPopup ?? false) titre=\(state?.label ?? "-") pastille=\(state?.badgeText ?? "-") onglet=\(tab?.currentURL?.absoluteString ?? "nil")")
        // setPanelBehavior({ openPanelOnActionClick: true }) : le bouton ouvre le panneau latéral au lieu de lancer l'action.
        if let context = contexts[id], let path = bridge.opensPanelOnActionClick(context) {
            do { try bridge.openSidePanel(for: context, path: path); return } catch { windowController?.noticePill.show(message: "Panneau latéral : \(error.localizedDescription)", button: "OK", seconds: 6) { } }
        }
        contexts[id]?.performAction(for: tab)
    }

    /// For tests and the automation channel.
    func report() -> String {
        guard !contexts.isEmpty else { return "no extensions loaded" }
        let tab = windowController?.activeExtensionTab
        return contexts.values.map { context in
            let action = context.action(for: tab)
            return "\(context.webExtension.displayName ?? "?") v\(context.webExtension.displayVersion ?? "?") loaded=\(context.isLoaded) errors=\(context.errors.map { $0.localizedDescription }) label=\(action?.label ?? "-") badge=\(action?.badgeText ?? "-") popup=\(action?.presentsPopup ?? false) enabled=\(action?.isEnabled ?? false) title=\(action?.label ?? "-")"
        }.sorted().joined(separator: " | ")
    }

    // MARK: WKWebExtensionControllerDelegate

    @objc(webExtensionController:focusedWindowForExtensionContext:)
    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        bridge.note("délégué : fenêtre active demandée")
        return windowController
    }

    @objc(webExtensionController:openWindowsForExtensionContext:)
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        bridge.note("délégué : fenêtres ouvertes demandées")
        return windowController.map { [$0] } ?? []
    }

    @objc(webExtensionController:openNewTabUsingConfiguration:forExtensionContext:completionHandler:)
    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        bridge.note("délégué : nouvel onglet demandé")
        guard let windowController else { completionHandler(nil, CancellationError()); return }
        let tab: Tab
        if let url = configuration.url, url.scheme != "http", url.scheme != "https" { tab = windowController.newTab(extensionPage: url, context: extensionContext) }      // une page de l'extension elle-même
        else { tab = windowController.newTab(urlString: configuration.url?.absoluteString, isPrivate: false) }
        completionHandler(tab, nil)
    }

    @objc(webExtensionController:sendMessage:toApplicationWithIdentifier:forExtensionContext:replyHandler:)
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        bridge.note("délégué : message natif vers \(applicationIdentifier ?? "?")")
        if let host = applicationIdentifier, host != ExtensionBridge.applicationID {
            nonisolated(unsafe) let request = message, reply = replyHandler
            Task { @MainActor in
                do { reply(try await self.bridge.nativeHostOneShot(host, message: request, context: extensionContext), nil) }
                catch { reply(nil, NSError(domain: "Orée", code: 1, userInfo: [NSLocalizedDescriptionKey: (error as? ExtensionBridge.Failure)?.message ?? error.localizedDescription])) }
            }
            return
        }
        nonisolated(unsafe) let request = message, reply = replyHandler
        Task { @MainActor in reply(await self.bridge.handle(request, context: extensionContext), nil) }
    }

    @objc(webExtensionController:connectUsingMessagePort:forExtensionContext:completionHandler:)
    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort, for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let host = port.applicationIdentifier, host != ExtensionBridge.applicationID {
            nonisolated(unsafe) let p = port, done = completionHandler
            Task { @MainActor in
                do { try await self.bridge.nativeHostConnect(host, port: p, context: extensionContext); done(nil) }
                catch { done(NSError(domain: "Orée", code: 1, userInfo: [NSLocalizedDescriptionKey: (error as? ExtensionBridge.Failure)?.message ?? error.localizedDescription])) }
            }
            return
        }
        bridge.attach(port, context: extensionContext)
        completionHandler(nil)
    }

    @objc(webExtensionController:openOptionsPageForExtensionContext:completionHandler:)
    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let url = extensionContext.optionsPageURL { windowController?.newTab(extensionPage: url, context: extensionContext) }
        completionHandler(nil)
    }

    @objc(webExtensionController:promptForPermissions:inTab:forExtensionContext:completionHandler:)
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        bridge.note("délégué : permissions demandées")
        let names = permissions.map { Self.permissionNames[$0.rawValue] ?? $0.rawValue }.sorted().joined(separator: "\n• ")
        ask("« \(extensionContext.webExtension.displayName ?? "Une extension") » demande une autorisation", detail: "• \(names)") { granted in
            completionHandler(granted ? permissions : [], nil)
        }
    }

    @objc(webExtensionController:promptForPermissionToAccessURLs:inTab:forExtensionContext:completionHandler:)
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        bridge.note("délégué : accès aux adresses demandé")
        let hosts = Set(urls.compactMap(\.host)).sorted().prefix(5).joined(separator: ", ")
        ask("« \(extensionContext.webExtension.displayName ?? "Une extension") » veut accéder à des sites", detail: hosts) { granted in
            completionHandler(granted ? urls : [], nil)
        }
    }

    @objc(webExtensionController:promptForPermissionMatchPatterns:inTab:forExtensionContext:completionHandler:)
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        bridge.note("délégué : accès aux motifs demandé")
        let list = matchPatterns.map(\.string).sorted().prefix(5).joined(separator: ", ")
        ask("« \(extensionContext.webExtension.displayName ?? "Une extension") » veut accéder à des sites", detail: list) { granted in
            completionHandler(granted ? matchPatterns : [], nil)
        }
    }

    @objc(webExtensionController:didUpdateAction:forExtensionContext:)
    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        bridge.note("délégué : bouton mis à jour (titre=\(action.label) pastille=\(action.badgeText) actif=\(action.isEnabled) popup=\(action.presentsPopup))")
        onChange?()
    }

    @objc(webExtensionController:presentPopupForAction:forExtensionContext:completionHandler:)
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let windowController else { completionHandler(nil); return }
        windowController.presentExtensionPopup(action, for: context, completion: completionHandler)
    }
}

// MARK: - Essais automatiques (instance de développement lancée avec --automation)

extension ExtensionManager {
    /// `disable:N`, `enable:N`, `remove:N`, `report`, `popup:N` (clique le bouton, attend le popup et en lit le contenu), `options:N` (ouvre les réglages et en lit le titre).
    func automationOperation(_ op: String) async -> String {
        let parts = op.split(separator: ":").map(String.init)
        if parts.first == "report" { return report() }
        if parts.first == "calls" { return bridge.callLog.suffix(400).joined(separator: "\n") }
        if parts.first == "trace" { return (windowController?.extensionPopupTrace ?? []).joined(separator: " | ") }
        let list = installedExtensions()
        guard parts.count == 2, let n = Int(parts[1]), list.indices.contains(n) else { return "no extension" }
        let item = list[n]
        switch parts[0] {
        case "disable": setEnabled(false, id: item.id)
        case "enable": setEnabled(true, id: item.id)
        case "remove": remove(id: item.id)
        case "popup": return await popupProbe(id: item.id)
        case "sidepanel": return await sidePanelProbe()
        case "loadbg":
            return "retiré"
        case "commands":
            guard let context = contexts[item.id] else { return "?" }
            var lines = context.commands.map { "\($0.id) clé=\($0.activationKey ?? "-") modifs=\($0.modifierFlags.rawValue)" }
            if let first = context.commands.first { context.performCommand(first); lines.append("exécuté : \(first.id)") }
            return lines.joined(separator: " | ")
        case "actionnil": contexts[item.id]?.performAction(for: nil); return "ok"
        case "popupstart": return await popupProbe(id: item.id, readResult: false)
        case "popupread": return await popupRead(id: item.id)
        case "options": return await optionsProbe(id: item.id)
        default: return "unknown op"
        }
        return "\(parts[0]) done; installed now: \(installedExtensions().map { "\($0.name)(enabled=\($0.isEnabled))" })"
    }

    private func probeJSON(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Clique le bouton de l'extension, attend que l'app ait posé le popover, puis lit ce que la page du popup affiche.
    /// (`isShown` n'est vrai que si la fenêtre est visible à l'écran ; l'instance d'essai peut être cachée, on lit donc aussi le contenu.)
    private func popupProbe(id: String, readResult: Bool = true) async -> String {
        guard let windowController, let context = contexts[id] else { return probeJSON(["error": "no context"]) }
        windowController.shownExtensionPopover?.close(); windowController.shownExtensionPopover = nil; windowController.extensionPopupTrace = []
        let tab = windowController.activeExtensionTab
        performAction(id: id, for: tab)
        for _ in 0..<40 { if windowController.shownExtensionPopover != nil { break }; try? await Task.sleep(for: .milliseconds(100)) }
        guard let popover = windowController.shownExtensionPopover else {
            return probeJSON(["shown": false, "presentsPopup": context.action(for: tab)?.presentsPopup ?? false, "trace": windowController.extensionPopupTrace])
        }
        try? await Task.sleep(for: .milliseconds(800))
        if !readResult { return probeJSON(["shown": true]) }      // la suite se lit avec « popupread »
        // Une page de test qui travaille longtemps met « ... » dans son titre (#t) puis le remplace par son résultat : on l'attend (7 s au plus).
        if let web = context.action(for: tab)?.popupWebView { for _ in 0..<65 { if (try? await web.evaluateJavaScript("(document.getElementById('t')||{}).textContent")) as? String != "..." { break }; try? await Task.sleep(for: .milliseconds(100)) } }
        var out: [String: Any] = ["shown": true, "onScreen": popover.isShown, "trace": windowController.extensionPopupTrace, "size": "\(Int(popover.contentSize.width))x\(Int(popover.contentSize.height))", "wanted": "\(Int(popover.contentViewController?.preferredContentSize.width ?? 0))x\(Int(popover.contentViewController?.preferredContentSize.height ?? 0))"]
        if let web = context.action(for: tab)?.popupWebView {
            out["title"] = (try? await web.evaluateJavaScript("(document.getElementById('t')||{}).textContent || ''")) as? String ?? ""
            out["body"] = (try? await web.evaluateJavaScript("document.body ? document.body.innerText.slice(0, 80) : ''")) as? String ?? ""
        }
        popover.close(); context.action(for: tab)?.closePopup()
        return probeJSON(out)
    }

    /// Lit le résultat (#t) d'un popup ouvert avec « popupstart », en attendant jusqu'à 8 s qu'il ne soit plus « ... », puis le referme.
    private func popupRead(id: String) async -> String {
        guard let windowController, let context = contexts[id], let web = context.action(for: windowController.activeExtensionTab)?.popupWebView else { return probeJSON(["error": "aucun popup ouvert"]) }
        for _ in 0..<80 { let text = (try? await web.evaluateJavaScript("(document.getElementById('t')||{}).textContent")) as? String; if let text, !text.isEmpty, text != "..." { break }; try? await Task.sleep(for: .milliseconds(100)) }
        let title = (try? await web.evaluateJavaScript("(document.getElementById('t')||{}).textContent || ''")) as? String ?? ""
        windowController.shownExtensionPopover?.close(); context.action(for: windowController.activeExtensionTab)?.closePopup()
        return probeJSON(["title": title])
    }

    /// Le panneau latéral affiché : son adresse, son titre et le début de son texte.
    private func sidePanelProbe() async -> String {
        guard let panel = windowController?.webPanel, panel.isShown, let web = panel.currentWebView else { return probeJSON(["shown": false]) }
        try? await Task.sleep(for: .milliseconds(1500))
        let text = (try? await web.evaluateJavaScript("document.body ? document.body.innerText.slice(0, 200) : ''")) as? String ?? ""
        return probeJSON(["shown": true, "url": web.url?.absoluteString ?? "", "title": web.title ?? "", "text": text, "width": Int(web.bounds.width), "height": Int(web.bounds.height)])
    }

    private func optionsProbe(id: String) async -> String {
        guard let windowController else { return probeJSON(["error": "no window"]) }
        guard openOptions(id: id) else { return probeJSON(["opened": false]) }
        let wanted = contexts[id]?.optionsPageURL?.absoluteString ?? ""
        func optionsTab() -> Tab? { windowController.tabs.last { $0.webView?.url?.absoluteString == wanted } }
        for _ in 0..<50 { try? await Task.sleep(for: .milliseconds(100)); if let t = optionsTab(), t.webView?.isLoading == false { break } }
        let web = optionsTab()?.webView
        let title = (try? await web?.evaluateJavaScript("(document.getElementById('t')||{}).textContent || document.title || ''")) as? String ?? ""
        return probeJSON(["opened": true, "url": web?.url?.absoluteString ?? "", "title": title, "tabs": windowController.tabs.count, "loading": web?.isLoading ?? false, "optionsURL": contexts[id]?.optionsPageURL?.absoluteString ?? "nil", "tabURLs": windowController.tabs.map { $0.webView?.url?.absoluteString ?? "-" }])
    }
}
