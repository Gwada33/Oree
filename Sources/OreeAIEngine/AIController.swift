import Foundation
import OreeAIProtocol

/// Le chef d'orchestre du service : état de veille (froid / chaud / tiède), vérification du modèle, une tâche à la fois, événements.
/// Il ne connaît ni XPC ni llama.cpp : tout passe par `AIEngine` et par la fonction `emit`.
public actor AIController {
    private let engine: AIEngine
    private let pin: ModelPin
    private let modelURL: URL
    private let systemPrompt: String
    private let idleDelay: Duration
    private let emit: @Sendable (AIEvent) -> Void

    private var state: AIState = .cold
    private var modelState: AIModelState
    private var verified = false
    private var loaded = false
    private var running: (id: String, task: Task<Void, Never>)?
    private var idleTask: Task<Void, Never>?
    /// Les opérations qui changent l'état (réveil, mise en veille, lancement) se suivent en file : jamais deux à la fois.
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameter idleDelay: inactivité avant le passage en tiède (30 s dans le contrat).
    public init(engine: AIEngine, pin: ModelPin = .qwen35_2B, modelURL: URL? = nil, systemPrompt: String = AIPrompts.system,
                idleDelay: Duration = .seconds(30), emit: @escaping @Sendable (AIEvent) -> Void) {
        self.engine = engine; self.pin = pin; self.systemPrompt = systemPrompt; self.idleDelay = idleDelay; self.emit = emit
        let url = modelURL ?? ModelFile.url(for: pin)
        self.modelURL = url
        self.modelState = FileManager.default.fileExists(atPath: url.path) ? .verifying : .missing
    }

    public func status() -> AIStatus { AIStatus(state: state, model: modelState) }
    public var isBusy: Bool { running != nil }

    // MARK: Opérations publiques

    @discardableResult
    public func warmUp() async -> AIStatus {
        _ = await serial { await makeWarm() }
        return status()
    }

    /// Prend en charge une tâche. Renvoie `false` (et émet une erreur) si une autre tourne déjà ou si le modèle n'est pas prêt.
    @discardableResult
    public func run(_ request: AIRunRequest) async -> Bool {
        await serial {
            guard running == nil else {
                emit(.error(taskID: request.taskID, message: "Une tâche est déjà en cours.")); return false
            }
            guard await makeWarm() else {
                emit(.error(taskID: request.taskID, message: unavailableMessage())); return false
            }
            idleTask?.cancel()
            running = (request.taskID, Task { await self.generate(request) })
            return true
        }
    }

    public func cancel(taskID: String) {
        guard let running, running.id == taskID else { return }
        running.task.cancel()
    }

    /// État tiède : le prompt système est déjà en cache KV sur disque (écrit à sa création), on libère le contexte.
    public func coolDown() async { await serial { await makeTepid() } }

    /// Pression mémoire : on rend tout ce qu'on peut. Avertissement → tiède ; critique → froid (poids fermés, l'OS reprend les pages).
    public func memoryPressure(critical: Bool) async {
        running?.task.cancel()
        await serial {
            await makeTepid()
            if critical { await makeCold() }
        }
    }

    // MARK: Transitions (toujours appelées dans `serial`)

    private func serial<T>(_ operation: () async -> T) async -> T {
        if locked { await withCheckedContinuation { waiters.append($0) } } else { locked = true }
        defer { if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() } }
        return await operation()
    }

    private func makeWarm() async -> Bool {
        if state == .warm { scheduleIdle(); return true }
        if !verified {
            guard await verifyModel() else { return false }
        }
        await engine.prewarm(modelAt: modelURL)
        do {
            if !loaded { try await engine.load(modelAt: modelURL); loaded = true }
            try await engine.startContext(systemPrompt: systemPrompt)
        } catch {
            emit(.error(taskID: nil, message: "Le modèle n'a pas pu être chargé : \(error.localizedDescription)"))
            return false
        }
        setState(.warm)
        scheduleIdle()
        return true
    }

    private func verifyModel() async -> Bool {
        guard FileManager.default.fileExists(atPath: modelURL.path) else { modelState = .missing; broadcast(); return false }
        modelState = .verifying
        broadcast()
        let (url, pin, emit) = (modelURL, pin, emit)
        let result = await Task.detached(priority: .userInitiated) {
            ModelFile.verify(url, against: pin) { emit(.modelProgress(received: $0, total: pin.size)) }
        }.value
        modelState = result
        verified = result == .ready
        broadcast()
        return verified
    }

    private func makeTepid() async {
        guard state == .warm else { return }
        idleTask?.cancel()
        await engine.stopContext()
        setState(.tepid)
    }

    private func makeCold() async {
        guard loaded else { return }
        await engine.unload()
        loaded = false
        setState(.cold)
    }

    private func setState(_ new: AIState) { state = new; broadcast() }
    private func broadcast() { emit(.stateChanged(status())) }

    private func unavailableMessage() -> String {
        switch modelState {
        case .missing: "Le modèle n'est pas encore téléchargé."
        case .corrupt: "Le fichier du modèle est incomplet ou modifié : il faut le télécharger de nouveau."
        default: "Le modèle n'est pas prêt."
        }
    }

    // MARK: Génération

    private func generate(_ request: AIRunRequest) async {
        var answer = ""
        do {
            for try await piece in engine.generate(user: request.userText, maxTokens: 1024) {
                answer += piece
                emit(.textDelta(taskID: request.taskID, text: piece))
            }
            try Task.checkCancellation()
            emit(.done(taskID: request.taskID, answer: answer, sources: []))
        } catch is CancellationError {
            emit(.error(taskID: request.taskID, message: "Tâche annulée."))
        } catch {
            emit(.error(taskID: request.taskID, message: error.localizedDescription))
        }
        running = nil
        scheduleIdle()
    }

    /// Après `idleDelay` sans activité (et sans tâche en cours), on passe en tiède.
    private func scheduleIdle() {
        idleTask?.cancel()
        let delay = idleDelay
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.idleElapsed()
        }
    }

    private func idleElapsed() async {
        guard running == nil else { return }
        await serial { if running == nil { await makeTepid() } }
    }
}
