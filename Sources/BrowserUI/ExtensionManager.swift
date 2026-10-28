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
    weak var windowController: BrowserWindowController?
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
        let configuration = WKWebExtensionController.Configuration(identifier: UUID(uuidString: "6E7A9C52-4B1D-4F3A-9D0E-48A5B6C7D8E9")!)
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
        if let data = try? Data(contentsOf: recordsFile), let saved = try? JSONDecoder().decode([Record].self, from: data) {
            records = saved
        }
    }

    var hasEnabledExtensions: Bool { records.contains { $0.enabled } }

    // MARK: Loading

    private var windowRegistered = false
    /// Le moteur doit connaître la fenêtre (et ses onglets) : sans cela, « clic sur le bouton d'une extension » pour un onglet ne fait rien.
    private func registerWindowIfNeeded() {
        guard !windowRegistered, let windowController else { return }
        windowRegistered = true
        controller.didOpenWindow(windowController)
        controller.didFocusWindow(windowController)
        for tab in windowController.extensionTabs { controller.didOpenTab(tab) }
        if let active = windowController.activeExtensionTab { controller.didActivateTab(active, previousActiveTab: nil); controller.didSelectTabs([active]) }
    }

    func loadAll() async {
        registerWindowIfNeeded()
        for record in records where record.enabled { await load(record) }
        onChange?()
    }

    private func load(_ record: Record) async {
        let directory = root.appendingPathComponent(record.directory, isDirectory: true)
        do {
            let webExtension = try await WKWebExtension(resourceBaseURL: directory)
            let context = WKWebExtensionContext(for: webExtension)
            context.uniqueIdentifier = record.id
            // The user approved these when installing.
            for permission in webExtension.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
            for pattern in webExtension.allRequestedMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
            try controller.load(context)
            contexts[record.id] = context
        } catch {
            Log.tabs.error("Could not load extension \(record.id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
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

    private static func manifestName(at directory: URL) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return json["name"] as? String
    }

    func install(from url: URL) async throws {
        registerWindowIfNeeded()
        let id = UUID().uuidString
        let destination = root.appendingPathComponent(id, isDirectory: true)
        let unpacked: URL
        do {
            unpacked = try ExtensionPackage.unpack(url, to: destination)
            let webExtension = try await WKWebExtension(resourceBaseURL: unpacked)
            guard await approveInstall(of: webExtension) else { throw CancellationError() }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        let relative = String(unpacked.path.dropFirst(root.path.count + 1))
        let record = Record(id: id, directory: relative, enabled: true)
        records.append(record)
        save()
        await load(record)
        onChange?()
        if let windowController { for tab in windowController.extensionTabs { controller.didOpenTab(tab) } }      // le nouveau contexte doit connaître les onglets déjà ouverts
    }

    func setEnabled(_ enabled: Bool, id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].enabled != enabled else { return }
        records[index].enabled = enabled
        save()
        if enabled {
            let record = records[index]
            Task { await load(record); onChange?() }
        } else if let context = contexts.removeValue(forKey: id) {
            try? controller.unload(context)
            onChange?()
        }
    }

    func remove(id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        if let context = contexts.removeValue(forKey: id) { try? controller.unload(context) }
        let record = records.remove(at: index)
        save()
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
    ]

    private func describe(_ webExtension: WKWebExtension) -> String {
        var lines = webExtension.requestedPermissions.map { Self.permissionNames[$0.rawValue] ?? "Permission « \($0.rawValue) »" }.sorted()
        let patterns = webExtension.allRequestedMatchPatterns.map(\.string).sorted()
        if patterns.contains(where: { $0 == "<all_urls>" || $0.hasPrefix("*://*/") }) {
            lines.append("Lire et modifier TOUTES les pages que vous visitez")
        } else if !patterns.isEmpty {
            lines.append("Lire et modifier les pages de : " + patterns.prefix(4).joined(separator: ", ") + (patterns.count > 4 ? "…" : ""))
        }
        return lines.isEmpty ? "Aucune permission particulière." : lines.map { "• \($0)" }.joined(separator: "\n")
    }

    private func approveInstall(of webExtension: WKWebExtension) async -> Bool {
        if autoApprove { return true }
        guard let window = windowController?.window else { return false }
        let alert = NSAlert()
        alert.messageText = "Installer « \(webExtension.displayName ?? "cette extension") » ?"
        alert.informativeText = "Cette extension pourra :\n\n\(describe(webExtension))"
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

    func performAction(id: String, for tab: Tab?) {
        contexts[id]?.performAction(for: tab)
    }

    /// For tests and the automation channel.
    func report() -> String {
        guard !contexts.isEmpty else { return "no extensions loaded" }
        let tab = windowController?.activeExtensionTab
        return contexts.values.map { context in
            let action = context.action(for: tab)
            return "\(context.webExtension.displayName ?? "?") v\(context.webExtension.displayVersion ?? "?") loaded=\(context.isLoaded) errors=\(context.errors.map { $0.localizedDescription }) label=\(action?.label ?? "-") badge=\(action?.badgeText ?? "-") popup=\(action?.presentsPopup ?? false)"
        }.sorted().joined(separator: " | ")
    }

    // MARK: WKWebExtensionControllerDelegate

    @objc(webExtensionController:focusedWindowForExtensionContext:)
    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        windowController
    }

    @objc(webExtensionController:openWindowsForExtensionContext:)
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        windowController.map { [$0] } ?? []
    }

    @objc(webExtensionController:openNewTabUsingConfiguration:forExtensionContext:completionHandler:)
    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        guard let windowController else { completionHandler(nil, CancellationError()); return }
        let tab: Tab
        if let url = configuration.url, url.scheme != "http", url.scheme != "https" { tab = windowController.newTab(extensionPage: url, context: extensionContext) }      // une page de l'extension elle-même
        else { tab = windowController.newTab(urlString: configuration.url?.absoluteString, isPrivate: false) }
        completionHandler(tab, nil)
    }

    @objc(webExtensionController:openOptionsPageForExtensionContext:completionHandler:)
    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let url = extensionContext.optionsPageURL { windowController?.newTab(extensionPage: url, context: extensionContext) }
        completionHandler(nil)
    }

    @objc(webExtensionController:promptForPermissions:inTab:forExtensionContext:completionHandler:)
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let names = permissions.map { Self.permissionNames[$0.rawValue] ?? $0.rawValue }.sorted().joined(separator: "\n• ")
        ask("« \(extensionContext.webExtension.displayName ?? "Une extension") » demande une autorisation", detail: "• \(names)") { granted in
            completionHandler(granted ? permissions : [], nil)
        }
    }

    @objc(webExtensionController:promptForPermissionToAccessURLs:inTab:forExtensionContext:completionHandler:)
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let hosts = Set(urls.compactMap(\.host)).sorted().prefix(5).joined(separator: ", ")
        ask("« \(extensionContext.webExtension.displayName ?? "Une extension") » veut accéder à des sites", detail: hosts) { granted in
            completionHandler(granted ? urls : [], nil)
        }
    }

    @objc(webExtensionController:promptForPermissionMatchPatterns:inTab:forExtensionContext:completionHandler:)
    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let list = matchPatterns.map(\.string).sorted().prefix(5).joined(separator: ", ")
        ask("« \(extensionContext.webExtension.displayName ?? "Une extension") » veut accéder à des sites", detail: list) { granted in
            completionHandler(granted ? matchPatterns : [], nil)
        }
    }

    @objc(webExtensionController:didUpdateAction:forExtensionContext:)
    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
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
        let list = installedExtensions()
        guard parts.count == 2, let n = Int(parts[1]), list.indices.contains(n) else { return "no extension" }
        let item = list[n]
        switch parts[0] {
        case "disable": setEnabled(false, id: item.id)
        case "enable": setEnabled(true, id: item.id)
        case "remove": remove(id: item.id)
        case "popup": return await popupProbe(id: item.id)
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
    private func popupProbe(id: String) async -> String {
        guard let windowController, let context = contexts[id] else { return probeJSON(["error": "no context"]) }
        windowController.shownExtensionPopover?.close(); windowController.shownExtensionPopover = nil; windowController.extensionPopupTrace = []
        let tab = windowController.activeExtensionTab
        performAction(id: id, for: tab)
        for _ in 0..<40 { if windowController.shownExtensionPopover != nil { break }; try? await Task.sleep(for: .milliseconds(100)) }
        guard let popover = windowController.shownExtensionPopover else {
            return probeJSON(["shown": false, "presentsPopup": context.action(for: tab)?.presentsPopup ?? false, "trace": windowController.extensionPopupTrace])
        }
        try? await Task.sleep(for: .milliseconds(800))
        var out: [String: Any] = ["shown": true, "onScreen": popover.isShown, "trace": windowController.extensionPopupTrace, "size": "\(Int(popover.contentSize.width))x\(Int(popover.contentSize.height))", "wanted": "\(Int(popover.contentViewController?.preferredContentSize.width ?? 0))x\(Int(popover.contentViewController?.preferredContentSize.height ?? 0))"]
        if let web = context.action(for: tab)?.popupWebView {
            out["title"] = (try? await web.evaluateJavaScript("(document.getElementById('t')||{}).textContent || ''")) as? String ?? ""
            out["body"] = (try? await web.evaluateJavaScript("document.body ? document.body.innerText.slice(0, 80) : ''")) as? String ?? ""
        }
        popover.close(); context.action(for: tab)?.closePopup()
        return probeJSON(out)
    }

    private func optionsProbe(id: String) async -> String {
        guard let windowController else { return probeJSON(["error": "no window"]) }
        guard openOptions(id: id) else { return probeJSON(["opened": false]) }
        for _ in 0..<50 { try? await Task.sleep(for: .milliseconds(100)); if windowController.activeTab?.webView?.isLoading == false, windowController.activeTab?.webView?.url?.scheme?.contains("extension") == true { break } }
        let web = windowController.activeTab?.webView
        let title = (try? await web?.evaluateJavaScript("(document.getElementById('t')||{}).textContent || document.title || ''")) as? String ?? ""
        return probeJSON(["opened": true, "url": web?.url?.absoluteString ?? "", "title": title, "tabs": windowController.tabs.count, "loading": web?.isLoading ?? false, "optionsURL": contexts[id]?.optionsPageURL?.absoluteString ?? "nil", "tabURLs": windowController.tabs.map { $0.webView?.url?.absoluteString ?? "-" }])
    }
}
