import AppKit
import WebKit
import BrowserCore
import UserNotifications

/// L'état des panneaux latéraux et des pages cachées des extensions.
@MainActor
final class PanelStates {
    struct SidePanel { var path: String?; var openOnClick = false; var enabled = true }
    var sidePanels: [String: SidePanel] = [:]
    var openContext: String?
    var offscreen: [String: WKWebView] = [:]
}

extension ExtensionBridge {
    /// L'adresse d'une page de l'extension ; refuse toute adresse qui sortirait de l'extension.
    private func pageURL(_ path: String, in context: WKWebExtensionContext) throws -> URL {
        guard let url = URL(string: path, relativeTo: context.baseURL)?.absoluteURL, url.scheme == context.baseURL.scheme, url.host == context.baseURL.host else {
            throw Failure(message: "Le chemin doit désigner une page de l'extension.")
        }
        return url
    }

    func openSidePanel(for context: WKWebExtensionContext, path: String?) throws {
        guard let window else { throw Failure(message: "fenêtre indisponible") }
        guard let path = path ?? panels.sidePanels[context.uniqueIdentifier]?.path else { throw Failure(message: "No sidePanel path set") }
        if panels.sidePanels[context.uniqueIdentifier]?.enabled == false { throw Failure(message: "Le panneau latéral est désactivé.") }
        let url = try pageURL(path, in: context)
        window.webPanel.overrides[url.absoluteString] = context.webViewConfiguration
        window.webPanel.show(WebPanelEntry(name: context.webExtension.displayName ?? "Extension", url: url.absoluteString))
        panels.openContext = context.uniqueIdentifier
    }

    /// Un clic sur le bouton de l'extension ouvre-t-il son panneau latéral (setPanelBehavior) ?
    func opensPanelOnActionClick(_ context: WKWebExtensionContext) -> String? {
        guard let state = panels.sidePanels[context.uniqueIdentifier], state.openOnClick, state.enabled else { return nil }
        return state.path
    }

    /// L'extension est déchargée ou retirée : ses pages cachées et son panneau partent avec elle.
    func unload(_ contextID: String) {
        panels.offscreen.removeValue(forKey: contextID)?.stopLoading()
        panels.sidePanels[contextID] = nil
        if panels.openContext == contextID { window?.webPanel.hide(); panels.openContext = nil }
        ports[contextID] = nil
    }

    func panelMethods() -> [String: Method] {
        [
            "sidePanel.setOptions": Method(permission: "sidePanel") { [self] a, context in
                var s = panels.sidePanels[context.uniqueIdentifier] ?? .init()
                if let path = a["path"] as? String { s.path = path }
                if let enabled = a["enabled"] as? Bool { s.enabled = enabled }
                panels.sidePanels[context.uniqueIdentifier] = s; return NSNull()
            },
            "sidePanel.setPanelBehavior": Method(permission: "sidePanel") { [self] a, context in
                var s = panels.sidePanels[context.uniqueIdentifier] ?? .init()
                s.openOnClick = (a["openPanelOnActionClick"] as? Bool) ?? false
                if let path = a["path"] as? String { s.path = path }
                panels.sidePanels[context.uniqueIdentifier] = s; return NSNull()
            },
            "sidePanel.open": Method(permission: "sidePanel") { [self] a, context in try openSidePanel(for: context, path: a["path"] as? String); return NSNull() },
            "sidePanel.close": Method(permission: "sidePanel") { [self] _, context in
                if panels.openContext == context.uniqueIdentifier { window?.webPanel.hide(); panels.openContext = nil }; return NSNull()
            },
            "sidePanel.isOpen": Method(permission: nil) { [self] _, context in panels.openContext == context.uniqueIdentifier && window?.webPanel.isShown == true },
            // MARK: offscreen : une page de l'extension chargée sans fenêtre visible
            "offscreen.create": Method(permission: "offscreen") { [self] a, context in
                let id = context.uniqueIdentifier
                if panels.offscreen[id] != nil { throw Failure(message: "Only a single offscreen document may be created.") }
                let url = try pageURL((a["url"] as? String) ?? "", in: context)
                let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: context.webViewConfiguration ?? WKWebViewConfiguration())
                web.load(URLRequest(url: url))
                panels.offscreen[id] = web; return NSNull()
            },
            "offscreen.close": Method(permission: "offscreen") { [self] _, context in
                guard let web = panels.offscreen.removeValue(forKey: context.uniqueIdentifier) else { throw Failure(message: "No current offscreen document.") }
                web.stopLoading(); return NSNull()
            },
            "offscreen.has": Method(permission: nil) { [self] _, context in panels.offscreen[context.uniqueIdentifier] != nil },
        ]
    }
}

// MARK: - Notifications

@MainActor
final class NotificationCenterBridge: NSObject, UNUserNotificationCenterDelegate {
    /// (identifiant de l'extension, événement, données) : l'app les renvoie à l'extension.
    var emit: ((String, String, Any) -> Void)?
    private var known: [String: Set<String>] = [:]        // extension → identifiants de notifications affichées
    private var counter = 0
    private var started = false
    private var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private func start() {
        guard !started, available else { return }
        started = true
        UNUserNotificationCenter.current().delegate = self
    }

    func create(contextID: String, name: String, id requested: String, options: [String: Any], deliver: Bool) async throws -> String {
        let id = requested.isEmpty ? { counter += 1; return "oree-notification-\(counter)" }() : requested
        known[contextID, default: []].insert(id)
        guard deliver, available else { return id }
        start()
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { known[contextID]?.remove(id); throw ExtensionBridge.Failure(message: "Les notifications d'Orée sont désactivées dans Réglages Système › Notifications.") }
        let content = UNMutableNotificationContent()
        content.title = (options["title"] as? String) ?? name
        var lines = [(options["message"] as? String) ?? ""]
        if let items = options["items"] as? [[String: Any]] { lines += items.map { "\($0["title"] ?? "") \($0["message"] ?? "")" } }
        if let progress = options["progress"] as? Int { lines.append("\(progress) %") }
        content.body = lines.filter { !$0.isEmpty }.joined(separator: "\n")
        content.subtitle = (options["contextMessage"] as? String) ?? ""
        if (options["silent"] as? Bool) != true { content.sound = .default }
        let buttons = (options["buttons"] as? [[String: Any]]) ?? []
        let category = "oree.\(contextID).\(id)"
        center.setNotificationCategories(Set([UNNotificationCategory(identifier: category, actions: buttons.prefix(2).enumerated().map { UNNotificationAction(identifier: "button.\($0.offset)", title: ($0.element["title"] as? String) ?? "", options: []) }, intentIdentifiers: [], options: [.customDismissAction])]))
        content.categoryIdentifier = category
        content.userInfo = ["context": contextID, "id": id]
        try await center.add(UNNotificationRequest(identifier: "\(contextID)|\(id)", content: content, trigger: nil))
        return id
    }

    func clear(contextID: String, id: String) -> Bool {
        let had = known[contextID]?.remove(id) != nil
        if available { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["\(contextID)|\(id)"]) }
        return had
    }

    func all(contextID: String) -> [String: Bool] { Dictionary(uniqueKeysWithValues: (known[contextID] ?? []).map { ($0, true) }) }

    func level() async -> String {
        guard available else { return "denied" }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .denied ? "denied" : "granted"
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .list, .sound] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let contextID = info["context"] as? String, let id = info["id"] as? String else { return }
        let action = response.actionIdentifier
        await MainActor.run {
            if action.hasPrefix("button."), let index = Int(action.dropFirst(7)) { emit?(contextID, "notifications.onButtonClicked", [id, index]) }
            else if action == UNNotificationDismissActionIdentifier { known[contextID]?.remove(id); emit?(contextID, "notifications.onClosed", [id, true]) }
            else { emit?(contextID, "notifications.onClicked", [id]) }
        }
    }
}

extension ExtensionBridge {
    func notificationMethods() -> [String: Method] {
        [
            "notifications.create": Method(permission: "notifications") { [self] a, context in
                let id = try await notifications.create(contextID: context.uniqueIdentifier, name: context.webExtension.displayName ?? "Extension", id: (a["id"] as? String) ?? "", options: (a["options"] as? [String: Any]) ?? [:], deliver: !(manager?.autoApprove ?? false))
                return id
            },
            "notifications.update": Method(permission: "notifications") { [self] a, context in
                let id = (a["id"] as? String) ?? ""
                guard notifications.all(contextID: context.uniqueIdentifier)[id] != nil else { return false }
                _ = try await notifications.create(contextID: context.uniqueIdentifier, name: context.webExtension.displayName ?? "Extension", id: id, options: (a["options"] as? [String: Any]) ?? [:], deliver: !(manager?.autoApprove ?? false)); return true
            },
            "notifications.clear": Method(permission: "notifications") { [self] a, context in notifications.clear(contextID: context.uniqueIdentifier, id: (a["id"] as? String) ?? "") },
            "notifications.getAll": Method(permission: "notifications") { [self] _, context in notifications.all(contextID: context.uniqueIdentifier) },
            "notifications.getPermissionLevel": Method(permission: "notifications") { [self] _, _ in await notifications.level() },
        ]
    }
}
