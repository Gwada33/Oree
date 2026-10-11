import Foundation
import CryptoKit
@testable import OreeAIEngine
import OreeAIProtocol

/// Moteur factice : enregistre les appels et répond avec un texte écrit d'avance.
final class FakeEngine: AIEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    var pieces = ["Bon", "jour", " !"]
    /// Pause entre deux morceaux (pour pouvoir annuler en cours de route).
    var delay: Duration = .zero
    var failLoad = false

    private func log(_ call: String) { lock.lock(); _calls.append(call); lock.unlock() }

    func load(modelAt url: URL) async throws {
        log("load")
        if failLoad { throw NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: "refusé"]) }
    }
    func prewarm() async { log("prewarm") }
    func startContext(systemPrompt: String) async throws { log("startContext") }
    func stopContext() async { log("stopContext") }
    func unload() async { log("unload") }

    func generate(user: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        log("generate:\(user)")
        let (pieces, delay) = (pieces, delay)
        return AsyncThrowingStream { continuation in
            let task = Task {
                for piece in pieces {
                    if Task.isCancelled { continuation.finish(throwing: CancellationError()); return }
                    continuation.yield(piece)
                    try? await Task.sleep(for: delay)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Un fichier de « modèle » minuscule avec son épinglage, dans un dossier jetable.
struct FakeModel {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oree-ai-test-\(UUID().uuidString)")
    let pin: ModelPin
    var url: URL { directory.appendingPathComponent(pin.name) }

    init(content: String = "contenu du modèle") {
        let data = Data(content.utf8)
        pin = ModelPin(name: "faux.gguf", size: Int64(data.count),
                       sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), url: URL(string: "https://example.com")!)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func write(_ content: String = "contenu du modèle") { try? Data(content.utf8).write(to: url) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// Récupère les événements émis, dans l'ordre.
final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [AIEvent] = []
    var list: [AIEvent] { lock.lock(); defer { lock.unlock() }; return all }
    func append(_ event: AIEvent) { lock.lock(); all.append(event); lock.unlock() }

    func waitFor(timeout: Double = 5, _ predicate: (AIEvent) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if list.contains(where: predicate) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
