import Testing
import Foundation
@testable import OreeAIEngine
import OreeAIProtocol

/// Côté navigateur, en miniature : reçoit les événements poussés par le service.
private final class Observer: NSObject, OreeAIObserverXPC, @unchecked Sendable {
    let events = Events()
    func event(_ eventJSON: Data) { if let event = AIEvent.decode(eventJSON) { events.append(event) } }
}

@Suite struct XPCTests {
    private func connect(requirement: String?, model: FakeModel) -> (NSXPCConnection, NSXPCListener, Observer, AIListenerDelegate) {
        let hub = AIEventHub()
        let controller = AIController(engine: FakeEngine(), pin: model.pin, modelURL: model.url, emit: { hub.broadcast($0) })
        let delegate = AIListenerDelegate(controller: controller, hub: hub, requirement: requirement)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        let observer = Observer()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: OreeAIServiceXPC.self)
        connection.exportedInterface = NSXPCInterface(with: OreeAIObserverXPC.self)
        connection.exportedObject = observer
        connection.resume()
        return (connection, listener, observer, delegate)
    }

    private func ping(_ connection: NSXPCConnection) async -> String? {
        await withCheckedContinuation { continuation in
            final class Once: @unchecked Sendable { let lock = NSLock(); var done = false
                func run(_ body: () -> Void) { lock.lock(); let first = !done; done = true; lock.unlock(); if first { body() } } }
            let once = Once()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.run { continuation.resume(returning: nil) } } as? OreeAIServiceXPC
            proxy?.ping { version in once.run { continuation.resume(returning: version) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.run { continuation.resume(returning: nil) } }
        }
    }

    @Test func questionGoesThroughXPCAndAnswerComesBack() async throws {
        let model = FakeModel(); model.write(); defer { model.remove() }
        let (connection, listener, observer, delegate) = connect(requirement: nil, model: model)
        defer { connection.invalidate(); listener.invalidate(); withExtendedLifetime(delegate) {} }   // le listener ne garde son délégué que faiblement
        #expect(await ping(connection) == OreeAIServiceInfo.version)      // d'abord : la liaison fonctionne-t-elle ?
        let proxy = try #require(connection.remoteObjectProxy as? OreeAIServiceXPC)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in proxy.subscribe { c.resume() } }
        let request = try JSONEncoder().encode(AIRunRequest(taskID: "x", userText: "Bonjour ?"))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in proxy.run(request) { c.resume() } }
        #expect(await observer.events.waitFor { $0 == .done(taskID: "x", answer: "Bonjour !", sources: []) })
        let status: AIStatus = try await withCheckedThrowingContinuation { c in
            proxy.status { data in c.resume(with: Result { try JSONDecoder().decode(AIStatus.self, from: data) }) }
        }
        #expect(status.state == .warm)
    }

    /// Le test de sécurité : ce programme n'est pas Orée (identifiant de signature différent), le service doit le refuser.
    @Test func clientThatIsNotOreeIsRefused() async {
        let model = FakeModel(); model.write(); defer { model.remove() }
        let (connection, listener, _, delegate) = connect(requirement: AIListenerDelegate.oreeRequirement, model: model)
        defer { connection.invalidate(); listener.invalidate(); withExtendedLifetime(delegate) {} }
        #expect(await ping(connection) == nil)
        // Sans exigence, le même montage répond : le refus vient bien de la signature, pas d'un montage cassé.
        let (open, openListener, _, openDelegate) = connect(requirement: nil, model: model)
        defer { open.invalidate(); openListener.invalidate(); withExtendedLifetime(openDelegate) {} }
        #expect(await ping(open) == OreeAIServiceInfo.version)
    }
}
