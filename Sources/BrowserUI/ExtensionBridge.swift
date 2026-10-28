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
    private var ports: [String: [WKWebExtension.MessagePort]] = [:]

    struct Failure: Error { let message: String }

    /// Les méthodes : un nom → ce que l'app fait. Les familles d'API s'y ajoutent une par une.
    private func table(context: WKWebExtensionContext) -> [String: @MainActor ([String: Any]) async throws -> Any] {
        [
            "ping": { _ in ["pong": true] },
        ]
    }

    func handle(_ message: Any, context: WKWebExtensionContext) async -> [String: Any] {
        guard let request = message as? [String: Any], let method = request["m"] as? String else { return ["ok": false, "e": "requête illisible"] }
        guard let action = table(context: context)[method] else { return ["ok": false, "e": "méthode inconnue : \(method)"] }
        do { return ["ok": true, "r": try await action(request["a"] as? [String: Any] ?? [:])] }
        catch let failure as Failure { return ["ok": false, "e": failure.message] }
        catch { return ["ok": false, "e": error.localizedDescription] }
    }

    func attach(_ port: WKWebExtension.MessagePort, context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        ports[id, default: []].append(port)
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

    /// Envoie un événement à toutes les extensions connectées.
    func broadcast(_ event: String, _ data: Any) {
        for list in ports.values { for port in list { port.sendMessage(["ev": event, "d": data], completionHandler: nil) } }
    }
}
