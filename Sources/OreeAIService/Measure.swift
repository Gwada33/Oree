import Foundation
import OreeAIEngine

/// Mémoire du processus : empreinte (ce que macOS nous compte) et mémoire résidente (pages présentes, y compris les poids mappés).
enum Memory {
    static func footprintMB() -> Double {
        var info = rusage_info_current()
        let ok = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) } }
        return ok == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : -1
    }
    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }
}

/// Entoure un moteur pour chronométrer chaque étape et compter les morceaux de texte produits (≈ jetons).
final class TimedEngine: AIEngine, @unchecked Sendable {
    private let inner: AIEngine
    private let lock = NSLock()
    private(set) var seconds: [String: Double] = [:]
    private(set) var pieces = 0
    private(set) var firstPieceAt: Double?
    private(set) var lastPieceAt: Double?
    private(set) var generateStart: Double?

    init(_ inner: AIEngine) { self.inner = inner }

    private func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    private func record(_ name: String, since start: Double) { lock.lock(); seconds[name] = now() - start; lock.unlock() }
    private func countPiece() { lock.lock(); pieces += 1; if firstPieceAt == nil { firstPieceAt = now() }; lastPieceAt = now(); lock.unlock() }
    func resetGeneration() { lock.lock(); pieces = 0; firstPieceAt = nil; lastPieceAt = nil; generateStart = nil; lock.unlock() }

    func load(modelAt url: URL) async throws { let t = now(); defer { record("load", since: t) }; try await inner.load(modelAt: url) }
    func prewarm(modelAt url: URL) async { let t = now(); await inner.prewarm(modelAt: url); record("prewarm", since: t) }
    func startContext(systemPrompt: String) async throws { let t = now(); defer { record("startContext", since: t) }; try await inner.startContext(systemPrompt: systemPrompt) }
    func stopContext() async { let t = now(); await inner.stopContext(); record("stopContext", since: t) }
    func unload() async { let t = now(); await inner.unload(); record("unload", since: t) }

    func generate(user: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        lock.lock(); generateStart = now(); lock.unlock()
        let upstream = inner.generate(user: user, maxTokens: maxTokens)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await piece in upstream {
                        self.countPiece()
                        continuation.yield(piece)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
