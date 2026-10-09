import Foundation
import DownloadKit

/// What the browser talks to. Two implementations: the real one over XPC (a separate process) and an
/// in-process fallback used only when that process cannot be started.
public protocol DownloadEngine: Sendable {
    func start(_ spec: DownloadRequestSpec) async -> StartOutcome
    func pause(_ id: UUID) async
    func resume(_ id: UUID) async
    func cancel(_ id: UUID) async
    func remove(_ id: UUID) async
    func list() async -> [DownloadSnapshot]
    func updates() -> AsyncStream<[DownloadSnapshot]>
    /// "browsing" / "idle": lets the engine lower its speed while a page is loading (phase 2 uses it).
    func setBrowsingActive(_ active: Bool) async
}

/// Runs the engine inside the calling process (fallback only).
public final class LocalEngine: DownloadEngine, @unchecked Sendable {
    public let manager: DownloadManager
    public init(manager: DownloadManager) { self.manager = manager }
    public func start(_ spec: DownloadRequestSpec) async -> StartOutcome { await manager.start(spec) }
    public func pause(_ id: UUID) async { await manager.pause(id) }
    public func resume(_ id: UUID) async { await manager.resume(id) }
    public func cancel(_ id: UUID) async { await manager.cancel(id) }
    public func remove(_ id: UUID) async { await manager.remove(id) }
    public func list() async -> [DownloadSnapshot] { await manager.list() }
    public func updates() -> AsyncStream<[DownloadSnapshot]> {
        // `updates()` is actor-isolated on the manager; bridge it into a stream we can hand out synchronously.
        AsyncStream { continuation in
            let task = Task {
                for await snapshots in await manager.updates() { continuation.yield(snapshots) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    public func setBrowsingActive(_ active: Bool) async { await manager.setBrowsingActive(active) }
}
