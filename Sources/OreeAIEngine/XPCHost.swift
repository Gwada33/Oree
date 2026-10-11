import Foundation
import OreeAIProtocol

/// Diffuse les événements du contrôleur à tous les navigateurs abonnés.
public final class AIEventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [UUID: @Sendable (Data) -> Void] = [:]

    public init() {}

    public func add(_ id: UUID, _ observer: @escaping @Sendable (Data) -> Void) { lock.lock(); observers[id] = observer; lock.unlock() }
    public func remove(_ id: UUID) { lock.lock(); observers[id] = nil; lock.unlock() }

    public func broadcast(_ event: AIEvent) {
        let data = event.encoded()
        lock.lock(); let all = Array(observers.values); lock.unlock()
        for observer in all { observer(data) }
    }
}

/// L'objet que le service exporte pour chaque connexion. Il traduit le JSON de XPC en appels au contrôleur.
public final class AIXPCService: NSObject, OreeAIServiceXPC, @unchecked Sendable {
    private let controller: AIController
    private let hub: AIEventHub
    private weak var connection: NSXPCConnection?
    private let id = UUID()

    init(controller: AIController, hub: AIEventHub, connection: NSXPCConnection?) {
        self.controller = controller; self.hub = hub; self.connection = connection
    }

    func stop() { hub.remove(id) }

    private static func json(_ status: AIStatus) -> Data { (try? JSONEncoder().encode(status)) ?? Data() }

    public func warmUp(reply: @escaping @Sendable (Data) -> Void) {
        let controller = controller
        Task { reply(Self.json(await controller.warmUp())) }
    }

    public func run(_ requestJSON: Data, reply: @escaping @Sendable () -> Void) {
        let controller = controller, hub = hub
        Task {
            if let request = try? JSONDecoder().decode(AIRunRequest.self, from: requestJSON) {
                await controller.run(request)
            } else {
                hub.broadcast(.error(taskID: nil, message: "Requête illisible."))
            }
            reply()
        }
    }

    // L'étape 1 n'a pas d'outils : le résultat d'un outil n'a nulle part où aller.
    public func toolResult(_ taskID: String, callID: String, text: String, reply: @escaping @Sendable () -> Void) { reply() }

    public func cancel(_ taskID: String, reply: @escaping @Sendable () -> Void) {
        let controller = controller
        Task { await controller.cancel(taskID: taskID); reply() }
    }

    public func coolDown(reply: @escaping @Sendable () -> Void) {
        let controller = controller
        Task { await controller.coolDown(); reply() }
    }

    public func status(reply: @escaping @Sendable (Data) -> Void) {
        let controller = controller
        Task { reply(Self.json(await controller.status())) }
    }

    public func subscribe(reply: @escaping @Sendable () -> Void) {
        hub.add(id) { [weak self] data in (self?.connection?.remoteObjectProxy as? OreeAIObserverXPC)?.event(data) }
        reply()
    }

    public func ping(reply: @escaping @Sendable (String) -> Void) { reply(OreeAIServiceInfo.version) }
}

/// Accepte les connexions — et seulement celles d'Orée.
public final class AIListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    /// Exigence de signature du client. Signature ad hoc : seul l'identifiant peut être épinglé (pas d'équipe Apple), donc ce n'est pas
    /// inviolable — mais un autre programme de la session est refusé. `nil` uniquement pour les tests d'intégration en processus.
    public static let oreeRequirement = "identifier \"com.nolhan.hyperbrowser\""

    private let controller: AIController
    private let hub: AIEventHub
    private let requirement: String?
    private let lock = NSLock()
    private var connections = 0

    public init(controller: AIController, hub: AIEventHub, requirement: String? = AIListenerDelegate.oreeRequirement) {
        self.controller = controller; self.hub = hub; self.requirement = requirement
    }

    public var connectionCount: Int { lock.lock(); defer { lock.unlock() }; return connections }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Avant `resume()` : un client qui ne correspond pas est coupé, ses messages ne sont jamais livrés.
        if let requirement { newConnection.setCodeSigningRequirement(requirement) }
        newConnection.exportedInterface = NSXPCInterface(with: OreeAIServiceXPC.self)
        newConnection.remoteObjectInterface = NSXPCInterface(with: OreeAIObserverXPC.self)
        let service = AIXPCService(controller: controller, hub: hub, connection: newConnection)
        newConnection.exportedObject = service
        lock.lock(); connections += 1; lock.unlock()
        newConnection.invalidationHandler = { [weak self, service] in
            service.stop()
            self?.lock.lock(); self?.connections -= 1; self?.lock.unlock()
        }
        newConnection.resume()
        return true
    }
}
