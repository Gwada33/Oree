import AppKit
import WebKit
import BrowserCore

/// Le pont entre les extensions et Orée : le script de compatibilité (`oree-compat.js`) y envoie, par la messagerie native de WebKit,
/// les appels des API Chrome que WebKit n'a pas (`chrome.history`, `chrome.debugger`…), et l'app y répond.
/// Requête : `{ "m": "history.search", "a": { … } }`. Réponse : `{ "ok": true, "r": … }` ou `{ "ok": false, "e": "texte" }`.
@MainActor
final class ExtensionBridge {
    weak var window: BrowserWindowController?
    /// Les connexions ouvertes par les extensions (pour leur envoyer des événements : `{ "ev": "downloads.onChanged", "d": … }`).
    var ports: [String: [WKWebExtension.MessagePort]] = [:]
    /// Les derniers appels (pour les essais automatiques et le diagnostic) : « méthode → ok / erreur ».
    private(set) var callLog: [String] = []
    let debug = DebuggerSessions()
    let panels = PanelStates()
    let notifications = NotificationCenterBridge()
    let system = SystemStates()
    let downloadWatch = DownloadWatch()
    let nativeHosts = NativeHostRegistry()
    weak var manager: ExtensionManager?
    let debuggerControllers = NSHashTable<WKUserContentController>.weakObjects()

    /// L'identifiant sous lequel le script de compatibilité parle à l'app (`sendNativeMessage('oree', …)`). Les autres identifiants sont des applications natives de l'extension.
    static let applicationID = "oree"

    struct Failure: Error { let message: String }

    init() {
        notifications.emit = { [weak self] id, event, data in self?.send(toContext: id, event: event, data) }
        system.emit = { [weak self] id, event, data in self?.send(toContext: id, event: event, data) }
    }

    /// Une méthode du pont : la permission du manifeste qu'elle exige (les extensions n'ont que ce qu'elles ont demandé à l'installation) et ce que l'app fait.
    struct Method {
        let permission: String?
        let run: @MainActor (_ args: [String: Any], _ context: WKWebExtensionContext) async throws -> Any
    }

    /// Les permissions que l'extension a demandées dans son manifeste d'origine (WebKit ne connaît que 14 permissions ; les autres, il les ignore).
    var permissions: (WKWebExtensionContext) -> Set<String> = { _ in [] }

    /// Toutes les méthodes. Chaque famille d'API est dans son fichier (ExtensionBridge+….swift).
    private func methods() -> [String: Method] {
        var all: [String: Method] = ["ping": Method(permission: nil) { _, _ in ["pong": true] }]
        all["log"] = Method(permission: nil) { [self] a, context in
            callLog.append("\(context.webExtension.displayName ?? "?") · \(a["kind"] ?? "journal") : \(a["message"] ?? "") \(a["where"] ?? "")"); return NSNull()
        }
        for family in [dataMethods(), debuggerMethods(), panelMethods(), notificationMethods(), systemMethods(), downloadMethods()] { all.merge(family) { first, _ in first } }
        return all
    }

    func note(_ text: String) { callLog.append(text); if callLog.count > 600 { callLog.removeFirst(callLog.count - 600) } }

    func handle(_ message: Any, context: WKWebExtensionContext) async -> [String: Any] {
        let reply = await run(message, context: context)
        let name = ((message as? [String: Any])?["m"] as? String) ?? "?"
        callLog.append("\(context.webExtension.displayName ?? "?") · \(name) → " + ((reply["ok"] as? Bool) == true ? "ok" : "ERREUR \(reply["e"] ?? "")"))
        if callLog.count > 600 { callLog.removeFirst(callLog.count - 600) }
        return reply
    }

    private func run(_ message: Any, context: WKWebExtensionContext) async -> [String: Any] {
        guard let request = message as? [String: Any], let name = request["m"] as? String else { return ["ok": false, "e": "requête illisible"] }
        guard let method = methods()[name] else { return ["ok": false, "e": "méthode inconnue : \(name)"] }
        if let needed = method.permission, !permissions(context).contains(needed) {
            return ["ok": false, "e": "Cette extension n'a pas demandé la permission « \(needed) »."]
        }
        do { return ["ok": true, "r": try await method.run(request["a"] as? [String: Any] ?? [:], context)] }
        catch let failure as Failure { return ["ok": false, "e": failure.message] }
        catch { return ["ok": false, "e": error.localizedDescription] }
    }

    func attach(_ port: WKWebExtension.MessagePort, context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        ports[id, default: []].append(port)
        startIdleWatch()
        port.messageHandler = { [weak self, weak port] message, _ in
            guard let message else { return }
            nonisolated(unsafe) let request = message
            Task { @MainActor in
                guard let self, let port else { return }
                var reply = await self.handle(request, context: context)
                if let rid = (request as? [String: Any])?["id"] { reply["id"] = rid }
                port.sendMessage(reply, completionHandler: nil)
            }
        }
        port.disconnectHandler = { [weak self] _ in
            nonisolated(unsafe) let gone = port
            Task { @MainActor in self?.ports[id]?.removeAll { $0 === gone } }
        }
    }

    /// Envoie un événement à une extension (toutes ses connexions).
    func send(toContext id: String, event: String, _ data: Any) {
        for port in ports[id] ?? [] { port.sendMessage(["ev": event, "d": data], completionHandler: nil) }
    }

    /// Envoie un événement à toutes les extensions connectées.
    func broadcast(_ event: String, _ data: Any) {
        for list in ports.values { for port in list { port.sendMessage(["ev": event, "d": data], completionHandler: nil) } }
    }
}
