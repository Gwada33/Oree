import Testing
import Foundation
@testable import OreeAIClient
import OreeAIProtocol

/// Un faux service : répond comme le vrai, sans modèle. Il pousse un texte par morceaux, comme le moteur.
private final class FakeService: NSObject, OreeAIServiceXPC, NSXPCListenerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var observer: OreeAIObserverXPC?
    private var status = AIStatus(state: .cold, model: .ready)
    private(set) var cancelled: [String] = []

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: OreeAIServiceXPC.self)
        connection.exportedObject = self
        connection.remoteObjectInterface = NSXPCInterface(with: OreeAIObserverXPC.self)
        lock.lock(); observer = connection.remoteObjectProxy as? OreeAIObserverXPC; lock.unlock()
        connection.resume()
        return true
    }
    private func push(_ event: AIEvent) { lock.lock(); let o = observer; lock.unlock(); o?.event(event.encoded()) }

    func warmUp(reply: @escaping @Sendable (Data) -> Void) {
        status.state = .warm
        push(.stateChanged(status))
        reply((try? JSONEncoder().encode(status)) ?? Data())
    }
    func run(_ requestJSON: Data, reply: @escaping @Sendable () -> Void) {
        guard let request = try? JSONDecoder().decode(AIRunRequest.self, from: requestJSON) else { reply(); return }
        reply()
        push(.textDelta(taskID: request.taskID, text: "Bon"))
        push(.textDelta(taskID: request.taskID, text: "jour !"))
        push(.done(taskID: request.taskID, answer: "Bonjour !", sources: []))
    }
    func toolResult(_ taskID: String, callID: String, text: String, reply: @escaping @Sendable () -> Void) { reply() }
    func cancel(_ taskID: String, reply: @escaping @Sendable () -> Void) { lock.lock(); cancelled.append(taskID); lock.unlock(); reply() }
    func coolDown(reply: @escaping @Sendable () -> Void) { status.state = .tepid; reply() }
    func status(reply: @escaping @Sendable (Data) -> Void) { reply((try? JSONEncoder().encode(status)) ?? Data()) }
    func subscribe(reply: @escaping @Sendable () -> Void) { reply() }
    func ping(reply: @escaping @Sendable (String) -> Void) { reply(OreeAIServiceInfo.version) }
}

/// Reçoit les événements jusqu'à une condition.
private func collect(_ client: AIClient, until done: @escaping @Sendable (AIEvent) -> Bool) async -> [AIEvent] {
    var seen: [AIEvent] = []
    let stream = client.events()
    return await withTaskGroup(of: [AIEvent].self) { group in
        group.addTask { var all: [AIEvent] = []; for await event in stream { all.append(event); if done(event) { break } }; return all }
        group.addTask { try? await Task.sleep(for: .seconds(4)); return [] }
        if let first = await group.next() { seen = first }
        group.cancelAll()
        return seen
    }
}

@Suite struct AIClientTests {
    private func connect(_ service: FakeService) -> (AIClient, NSXPCListener) {
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()
        return (AIClient(endpoint: listener.endpoint), listener)
    }

    @Test func pingStatusAndWarmUpGoThroughXPC() async throws {
        let service = FakeService()
        let (client, listener) = connect(service)
        defer { client.invalidate(); listener.invalidate(); withExtendedLifetime(service) {} }
        #expect(await client.ping())
        #expect(await client.status() == AIStatus(state: .cold, model: .ready))
        #expect(await client.warmUp()?.state == .warm)
    }

    @Test func aQuestionStreamsItsAnswerBack() async throws {
        let service = FakeService()
        let (client, listener) = connect(service)
        defer { client.invalidate(); listener.invalidate(); withExtendedLifetime(service) {} }
        #expect(await client.ping())
        async let events = collect(client) { if case .done = $0 { true } else { false } }
        try await Task.sleep(for: .milliseconds(150))                   // le lecteur est en place avant la question
        #expect(await client.run(AIRunRequest(taskID: "t1", userText: "Bonjour ?")))
        let seen = await events
        #expect(seen.contains(.textDelta(taskID: "t1", text: "Bon")) && seen.contains(.textDelta(taskID: "t1", text: "jour !")))
        #expect(seen.last == .done(taskID: "t1", answer: "Bonjour !", sources: []))
    }

    @Test func stopIsPassedToTheService() async {
        let service = FakeService()
        let (client, listener) = connect(service)
        defer { client.invalidate(); listener.invalidate(); withExtendedLifetime(service) {} }
        await client.cancel(taskID: "t2")
        #expect(service.cancelled == ["t2"])
    }

    @Test func anUnknownServiceIsUnreachableAndNeverBlocks() async {
        let client = AIClient(machService: "com.nolhan.hyperbrowser.ai-inexistant-\(UUID().uuidString.prefix(6))")
        defer { client.invalidate() }
        let started = Date()
        #expect(await client.ping(timeout: 3) == false)
        #expect(await client.status(timeout: 3) == nil)
        #expect(Date().timeIntervalSince(started) < 8)                 // un service absent ne fait pas attendre l'interface
    }
}

@Suite struct AIAvailabilityTests {
    private func availability(_ reachable: Bool?, _ status: AIStatus?, _ download: AIDownloadProgress? = nil) -> AIAvailability {
        AIAvailability(reachable: reachable, status: status, download: download)
    }

    @Test func eachModelStateMapsToWhatTheBarCanDo() {
        #expect(availability(nil, nil) == .connecting)
        #expect(availability(false, nil) == .unreachable)
        #expect(availability(true, nil) == .connecting)
        #expect(availability(true, AIStatus(state: .cold, model: .missing)) == .needsModel)
        #expect(availability(true, AIStatus(state: .cold, model: .verifying)) == .verifying)
        #expect(availability(true, AIStatus(state: .cold, model: .corrupt)) == .corrupt)
        #expect(availability(true, AIStatus(state: .warm, model: .ready)) == .ready(.warm))
    }

    @Test func onlyAReadyModelCanAnswerAndOnlyAMissingOrBrokenOneOffersTheDownload() {
        #expect(availability(true, AIStatus(state: .tepid, model: .ready)).canAsk)
        #expect(!availability(true, AIStatus(state: .cold, model: .missing)).canAsk)
        #expect(availability(true, AIStatus(state: .cold, model: .missing)).offersDownload)
        #expect(availability(true, AIStatus(state: .cold, model: .corrupt)).offersDownload)
        #expect(!availability(true, AIStatus(state: .cold, model: .ready)).offersDownload)
        #expect(!availability(false, nil).offersDownload)
    }

    @Test func aRunningDownloadWinsOverTheFileState() {
        let progress = AIDownloadProgress(received: 635_404_016, total: 1_270_808_032)
        #expect(availability(true, AIStatus(state: .cold, model: .missing), progress) == .downloading(progress))
        #expect(availability(true, AIStatus(state: .cold, model: .missing), progress).line(modelBytes: 1_270_808_032) == "Téléchargement du modèle : 50 % (635 Mo sur 1,3 Go)")
        #expect(!availability(true, AIStatus(state: .cold, model: .missing), progress).canAsk)
    }

    @Test func theWordsAreHonest() {
        let size: Int64 = 1_270_808_032
        #expect(AIAvailability.needsModel.line(modelBytes: size).contains("1,3 Go"))
        #expect(AIAvailability.ready(.warm).line(modelBytes: size) == "Prêt")
        #expect(AIAvailability.ready(.cold).line(modelBytes: size).contains("moins d'une seconde"))
        #expect(AIAvailability.downloading(AIDownloadProgress(received: 0, total: nil)).line(modelBytes: size) == "Téléchargement du modèle…")
    }
}
