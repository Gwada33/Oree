import Foundation
import DownloadKit

/// The Mach service name of the downloader agent.
public enum DownloaderService {
    public static let machName = "com.nolhan.hyperbrowser.downloader"
    public static let version = "1"
}

/// Messages are JSON `Data` (not custom classes): simple, versionable, no NSSecureCoding allow-lists.
@objc public protocol DownloadServiceXPC {
    func start(_ requestJSON: Data, reply: @escaping @Sendable (Data) -> Void)
    func pause(_ id: String, reply: @escaping @Sendable () -> Void)
    func resume(_ id: String, reply: @escaping @Sendable () -> Void)
    func cancel(_ id: String, reply: @escaping @Sendable () -> Void)
    func remove(_ id: String, reply: @escaping @Sendable () -> Void)
    func list(reply: @escaping @Sendable (Data) -> Void)
    /// After this, the service pushes `updated(_:)` to the caller's exported object.
    func subscribe(reply: @escaping @Sendable () -> Void)
    func setBrowsingActive(_ active: Bool, reply: @escaping @Sendable () -> Void)
    func ping(reply: @escaping @Sendable (String) -> Void)
}

@objc public protocol DownloadObserverXPC {
    func updated(_ snapshotsJSON: Data)
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) { lock.lock(); let first = !done; done = true; lock.unlock(); if first { body() } }
}

// MARK: - Service side

/// The object the downloader process exports for each client connection.
public final class DownloadXPCService: NSObject, DownloadServiceXPC, @unchecked Sendable {
    private let manager: DownloadManager
    private weak var connection: NSXPCConnection?
    private var pushTask: Task<Void, Never>?
    private let onBrowsing: @Sendable (Bool) -> Void

    public init(manager: DownloadManager, connection: NSXPCConnection?, onBrowsing: @escaping @Sendable (Bool) -> Void = { _ in }) {
        self.manager = manager
        self.connection = connection
        self.onBrowsing = onBrowsing
    }

    public func stop() { pushTask?.cancel() }

    public func start(_ requestJSON: Data, reply: @escaping @Sendable (Data) -> Void) {
        let manager = self.manager
        Task {
            let outcome: StartOutcome
            if let spec = try? JSONDecoder().decode(DownloadRequestSpec.self, from: requestJSON) { outcome = await manager.start(spec) }
            else { outcome = .unsupported(reason: "requête illisible") }
            reply((try? JSONEncoder().encode(outcome)) ?? Data())
        }
    }

    private func with(_ id: String, _ action: @escaping @Sendable (DownloadManager, UUID) async -> Void, reply: @escaping @Sendable () -> Void) {
        let manager = self.manager
        Task { if let uuid = UUID(uuidString: id) { await action(manager, uuid) }; reply() }
    }

    public func pause(_ id: String, reply: @escaping @Sendable () -> Void) { with(id, { await $0.pause($1) }, reply: reply) }
    public func resume(_ id: String, reply: @escaping @Sendable () -> Void) { with(id, { await $0.resume($1) }, reply: reply) }
    public func cancel(_ id: String, reply: @escaping @Sendable () -> Void) { with(id, { await $0.cancel($1) }, reply: reply) }
    public func remove(_ id: String, reply: @escaping @Sendable () -> Void) { with(id, { await $0.remove($1) }, reply: reply) }

    public func list(reply: @escaping @Sendable (Data) -> Void) {
        let manager = self.manager
        Task { reply((try? JSONEncoder().encode(await manager.list())) ?? Data()) }
    }

    public func subscribe(reply: @escaping @Sendable () -> Void) {
        pushTask?.cancel()
        let manager = self.manager
        let connection = self.connection
        pushTask = Task {
            for await snapshots in await manager.updates() {
                guard let data = try? JSONEncoder().encode(snapshots) else { continue }
                (connection?.remoteObjectProxy as? DownloadObserverXPC)?.updated(data)
            }
        }
        reply()
    }

    public func setBrowsingActive(_ active: Bool, reply: @escaping @Sendable () -> Void) { onBrowsing(active); reply() }

    public func ping(reply: @escaping @Sendable (String) -> Void) { reply(DownloaderService.version) }
}

/// Accepts connections (only from Orée), counts them so the process can exit when idle.
public final class DownloadListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let manager: DownloadManager
    private let lock = NSLock()
    private var connections = 0
    private let onBrowsing: @Sendable (Bool) -> Void

    /// - Parameter onBrowsing: defaults to forwarding "the browser is loading a page" to the engine (downloads slow down meanwhile).
    public init(manager: DownloadManager, onBrowsing: (@Sendable (Bool) -> Void)? = nil) {
        self.manager = manager
        self.onBrowsing = onBrowsing ?? { active in Task { await manager.setBrowsingActive(active) } }
    }

    public var connectionCount: Int { lock.lock(); defer { lock.unlock() }; return connections }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: DownloadServiceXPC.self)
        newConnection.remoteObjectInterface = NSXPCInterface(with: DownloadObserverXPC.self)
        let service = DownloadXPCService(manager: manager, connection: newConnection, onBrowsing: onBrowsing)
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

// MARK: - Client side

/// Receives the pushed progress and fans it out to everyone listening to `updates()`.
final class ObserverHub: NSObject, DownloadObserverXPC, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<[DownloadSnapshot]>.Continuation] = [:]

    func updated(_ snapshotsJSON: Data) {
        guard let snapshots = try? JSONDecoder().decode([DownloadSnapshot].self, from: snapshotsJSON) else { return }
        lock.lock(); let all = Array(continuations.values); lock.unlock()
        for continuation in all { continuation.yield(snapshots) }
    }

    func stream() -> AsyncStream<[DownloadSnapshot]> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock(); continuations[id] = continuation; lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.lock.lock(); self?.continuations[id] = nil; self?.lock.unlock() }
        }
    }
}

/// The browser's end of the XPC link. Reconnects (and re-subscribes) if the service goes away.
public final class XPCEngine: DownloadEngine, @unchecked Sendable {
    private let makeConnection: @Sendable () -> NSXPCConnection
    private let hub = ObserverHub()
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    public init(machService: String = DownloaderService.machName) {
        makeConnection = { NSXPCConnection(machServiceName: machService, options: []) }
    }

    /// For tests: connect to an in-process listener endpoint.
    public init(endpoint: NSXPCListenerEndpoint) {
        makeConnection = { NSXPCConnection(listenerEndpoint: endpoint) }
    }

    private func connected() -> NSXPCConnection {
        lock.lock(); defer { lock.unlock() }
        if let connection { return connection }
        let connection = makeConnection()
        connection.remoteObjectInterface = NSXPCInterface(with: DownloadServiceXPC.self)
        connection.exportedInterface = NSXPCInterface(with: DownloadObserverXPC.self)
        connection.exportedObject = hub
        connection.invalidationHandler = { [weak self] in self?.dropConnection() }
        connection.interruptionHandler = { [weak self] in self?.dropConnection() }
        connection.resume()
        self.connection = connection
        (connection.remoteObjectProxy as? DownloadServiceXPC)?.subscribe(reply: {})
        return connection
    }

    private func dropConnection() { lock.lock(); connection = nil; lock.unlock() }

    private func proxy(onError: @escaping @Sendable () -> Void) -> DownloadServiceXPC? {
        connected().remoteObjectProxyWithErrorHandler { _ in onError() } as? DownloadServiceXPC
    }

    /// Can we reach the service (starting it on demand if launchd knows it)?
    public func isReachable(timeout: TimeInterval = 3) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = Once()
            guard let proxy = proxy(onError: { once.run { continuation.resume(returning: false) } }) else { continuation.resume(returning: false); return }
            proxy.ping { _ in once.run { continuation.resume(returning: true) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.run { continuation.resume(returning: false) } }
        }
    }

    public func start(_ spec: DownloadRequestSpec) async -> StartOutcome {
        guard let json = try? JSONEncoder().encode(spec) else { return .unsupported(reason: "requête invalide") }
        return await withCheckedContinuation { continuation in
            let once = Once()
            guard let proxy = proxy(onError: { once.run { continuation.resume(returning: .unsupported(reason: "moteur indisponible")) } }) else {
                continuation.resume(returning: .unsupported(reason: "moteur indisponible")); return
            }
            proxy.start(json) { data in
                once.run { continuation.resume(returning: (try? JSONDecoder().decode(StartOutcome.self, from: data)) ?? .unsupported(reason: "réponse illisible")) }
            }
        }
    }

    private func simple(_ call: @escaping @Sendable (DownloadServiceXPC, @escaping @Sendable () -> Void) -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once()
            guard let proxy = proxy(onError: { once.run { continuation.resume() } }) else { continuation.resume(); return }
            call(proxy) { once.run { continuation.resume() } }
        }
    }

    public func pause(_ id: UUID) async { await simple { $0.pause(id.uuidString, reply: $1) } }
    public func resume(_ id: UUID) async { await simple { $0.resume(id.uuidString, reply: $1) } }
    public func cancel(_ id: UUID) async { await simple { $0.cancel(id.uuidString, reply: $1) } }
    public func remove(_ id: UUID) async { await simple { $0.remove(id.uuidString, reply: $1) } }
    public func setBrowsingActive(_ active: Bool) async { await simple { $0.setBrowsingActive(active, reply: $1) } }

    public func list() async -> [DownloadSnapshot] {
        await withCheckedContinuation { continuation in
            let once = Once()
            guard let proxy = proxy(onError: { once.run { continuation.resume(returning: []) } }) else { continuation.resume(returning: []); return }
            proxy.list { data in once.run { continuation.resume(returning: (try? JSONDecoder().decode([DownloadSnapshot].self, from: data)) ?? []) } }
        }
    }

    public func updates() -> AsyncStream<[DownloadSnapshot]> {
        _ = connected()           // make sure we are subscribed
        return hub.stream()
    }
}
