import Foundation
import OreeAIProtocol

/// Côté navigateur : parle au service IA local par XPC. Même méthode que `XPCEngine` du téléchargeur : la connexion se crée à la demande
/// (ce qui lance le service si launchd le connaît), se rétablit après une coupure, et un abonnement pousse les événements.
///
/// Toutes les attentes ont un délai : un service bloqué ne doit jamais bloquer l'interface.
public final class AIClient: @unchecked Sendable {
    private let makeConnection: @Sendable () -> NSXPCConnection
    private let hub = EventHub()
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    public init(machService: String = OreeAIServiceInfo.machName) {
        makeConnection = { NSXPCConnection(machServiceName: machService, options: []) }
    }

    /// Pour les tests : se connecte à un écouteur du même processus.
    public init(endpoint: NSXPCListenerEndpoint) {
        makeConnection = { NSXPCConnection(listenerEndpoint: endpoint) }
    }

    private func connected() -> NSXPCConnection {
        lock.lock(); defer { lock.unlock() }
        if let connection { return connection }
        let connection = makeConnection()
        connection.remoteObjectInterface = NSXPCInterface(with: OreeAIServiceXPC.self)
        connection.exportedInterface = NSXPCInterface(with: OreeAIObserverXPC.self)
        connection.exportedObject = ObserverBridge(hub: hub)
        connection.invalidationHandler = { [weak self] in self?.dropConnection() }
        connection.interruptionHandler = { [weak self] in self?.dropConnection() }
        connection.resume()
        self.connection = connection
        (connection.remoteObjectProxy as? OreeAIServiceXPC)?.subscribe(reply: {})
        return connection
    }

    private func dropConnection() { lock.lock(); connection = nil; lock.unlock() }

    /// Ferme la connexion (le service passera seul en tiède).
    public func invalidate() {
        lock.lock(); let current = connection; connection = nil; lock.unlock()
        current?.invalidate()
    }

    /// Une requête avec son délai. `nil` si le service ne répond pas, refuse la connexion ou ne répond pas à temps.
    private func call<T: Sendable>(timeout: TimeInterval, _ body: @escaping @Sendable (OreeAIServiceXPC, @escaping @Sendable (T) -> Void) -> Void) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = Once()
            guard let proxy = connected().remoteObjectProxyWithErrorHandler({ _ in once.run { continuation.resume(returning: nil) } }) as? OreeAIServiceXPC else {
                continuation.resume(returning: nil); return
            }
            body(proxy) { value in once.run { continuation.resume(returning: value) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.run { continuation.resume(returning: nil) } }
        }
    }

    /// Les événements du service (texte au fil de l'eau, fin, erreur, changement d'état). Une seule connexion, plusieurs lecteurs possibles.
    public func events() -> AsyncStream<AIEvent> {
        _ = connected()            // abonne le navigateur
        return hub.stream()
    }

    /// Le service répond-il (le lance-t-il à la demande) ?
    public func ping(timeout: TimeInterval = 6) async -> Bool {
        let version: String? = await call(timeout: timeout) { proxy, reply in proxy.ping(reply: reply) }
        return version != nil
    }

    /// État du modèle et de la veille. `nil` : service injoignable. Le premier appel peut durer ≈ 1 s (vérification du fichier du modèle).
    public func status(timeout: TimeInterval = 15) async -> AIStatus? {
        let data: Data? = await call(timeout: timeout) { proxy, reply in proxy.status(reply: reply) }
        return data.flatMap { try? JSONDecoder().decode(AIStatus.self, from: $0) }
    }

    /// Réveille le modèle (poids en mémoire, cache du prompt restauré) : à appeler quand la barre s'ouvre.
    public func warmUp(timeout: TimeInterval = 20) async -> AIStatus? {
        let data: Data? = await call(timeout: timeout) { proxy, reply in proxy.warmUp(reply: reply) }
        return data.flatMap { try? JSONDecoder().decode(AIStatus.self, from: $0) }
    }

    /// Lance une tâche. `true` : le service l'a prise en charge ; la réponse arrive par `events()`.
    public func run(_ request: AIRunRequest, timeout: TimeInterval = 15) async -> Bool {
        guard let json = try? JSONEncoder().encode(request) else { return false }
        let accepted: Bool? = await call(timeout: timeout) { proxy, reply in proxy.run(json) { reply(true) } }
        return accepted == true
    }

    public func cancel(taskID: String) async {
        let _: Bool? = await call(timeout: 5) { proxy, reply in proxy.cancel(taskID) { reply(true) } }
    }

    public func coolDown() async {
        let _: Bool? = await call(timeout: 5) { proxy, reply in proxy.coolDown { reply(true) } }
    }
}

/// Reçoit les événements poussés par le service et les passe aux lecteurs.
private final class ObserverBridge: NSObject, OreeAIObserverXPC, @unchecked Sendable {
    let hub: EventHub
    init(hub: EventHub) { self.hub = hub }
    func event(_ eventJSON: Data) { if let event = AIEvent.decode(eventJSON) { hub.yield(event) } }
}

final class EventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<AIEvent>.Continuation] = [:]

    func stream() -> AsyncStream<AIEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock(); continuations[id] = continuation; lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.lock.lock(); self?.continuations[id] = nil; self?.lock.unlock() }
        }
    }

    func yield(_ event: AIEvent) {
        lock.lock(); let all = Array(continuations.values); lock.unlock()
        for continuation in all { continuation.yield(event) }
    }
}

/// Exécute `body` une seule fois : la réponse, l'erreur de connexion et le délai se disputent la même reprise.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) { lock.lock(); let first = !done; done = true; lock.unlock(); if first { body() } }
}
