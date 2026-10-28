import AppKit
import WebKit
import BrowserCore

/// Messagerie native : une extension qui a la permission « nativeMessaging » peut parler à un programme de l'ordinateur dont la déclaration est rangée là où les
/// navigateurs Chrome la cherchent (voir `NativeMessaging.searchDirectories`) ET qui accepte cette extension (`allowed_origins`). Orée demande une fois à l'utilisateur,
/// par extension et par programme, avant de lancer quoi que ce soit.
@MainActor
final class NativeHostRegistry {
    var connections: [ObjectIdentifier: NativeHostConnection] = [:]
    private let key = "oree.extensions.nativeHostConsent"
    func isAllowed(extensionID: String, host: String) -> Bool { (UserDefaults.standard.stringArray(forKey: key) ?? []).contains("\(extensionID)|\(host)") }
    func allow(extensionID: String, host: String) { UserDefaults.standard.set(Array(Set((UserDefaults.standard.stringArray(forKey: key) ?? []) + ["\(extensionID)|\(host)"])), forKey: key) }
}

/// Un programme hôte lancé pour une extension : messages en JSON précédés de leur longueur, sur l'entrée et la sortie standard.
@MainActor
final class NativeHostConnection {
    let process = Process()
    private let input = Pipe(), output = Pipe()
    private var buffer = Data()
    var onMessage: ((Any) -> Void)?
    var onExit: (() -> Void)?

    init(host: NativeMessaging.Host, extensionID: String) throws {
        process.executableURL = URL(fileURLWithPath: host.path)
        process.arguments = ["chrome-extension://\(extensionID)/"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            nonisolated(unsafe) let chunk = data
            Task { @MainActor in self?.received(chunk) }
        }
        process.terminationHandler = { [weak self] _ in Task { @MainActor in self?.output.fileHandleForReading.readabilityHandler = nil; self?.onExit?() } }
        try process.run()
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        let split = NativeMessaging.split(buffer)
        buffer = split.rest
        if split.tooLarge { stop(); return }
        for message in split.messages { if let object = try? JSONSerialization.jsonObject(with: message, options: .fragmentsAllowed) { onMessage?(object) } }
    }

    func send(_ message: Any) throws {
        guard JSONSerialization.isValidJSONObject(message) || message is String || message is NSNumber else { throw ExtensionBridge.Failure(message: "Message invalide") }
        let data = try JSONSerialization.data(withJSONObject: message, options: .fragmentsAllowed)
        try input.fileHandleForWriting.write(contentsOf: NativeMessaging.frame(data))
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

extension ExtensionBridge {
    /// Trouve et autorise l'hôte ; lève une erreur lisible sinon.
    private func authorizedHost(_ name: String, context: WKWebExtensionContext) async throws -> NativeMessaging.Host {
        guard permissions(context).contains("nativeMessaging") else { throw Failure(message: "Cette extension n'a pas demandé la permission « nativeMessaging ». ") }
        let extra = ProcessInfo.processInfo.environment["HB_NATIVE_HOSTS_DIR"].map { [URL(fileURLWithPath: $0, isDirectory: true)] } ?? []
        let host: NativeMessaging.Host
        switch NativeMessaging.locate(name, extensionID: context.uniqueIdentifier, directories: NativeMessaging.searchDirectories(extra: extra)) {
        case .success(let found): host = found
        case .failure(.notAllowed): throw Failure(message: "Access to the specified native messaging host is forbidden.")
        case .failure(.invalidName): throw Failure(message: "Invalid native messaging host name specified.")
        case .failure(.notFound): throw Failure(message: "Specified native messaging host not found.")
        }
        if !nativeHosts.isAllowed(extensionID: context.uniqueIdentifier, host: name) {
            if !(manager?.autoApprove ?? false) {
                guard let w = window?.window else { throw Failure(message: "Fenêtre indisponible.") }
                let alert = NSAlert()
                alert.messageText = "Autoriser « \(context.webExtension.displayName ?? "cette extension") » à lancer un programme ?"
                alert.informativeText = "Elle veut parler au programme « \(name) » :\n\(host.path)\n\nN'acceptez que si vous l'avez installé vous-même (par exemple avec Claude Code)."
                alert.addButton(withTitle: "Autoriser"); alert.addButton(withTitle: "Refuser")
                let agreed = await withCheckedContinuation { c in alert.beginSheetModal(for: w) { c.resume(returning: $0 == .alertFirstButtonReturn) } }
                guard agreed else { throw Failure(message: "Access to the specified native messaging host is forbidden.") }
            }
            nativeHosts.allow(extensionID: context.uniqueIdentifier, host: name)
        }
        return host
    }

    /// `sendNativeMessage(hôte, message)` : lance l'hôte, lui envoie le message, rend sa première réponse, l'arrête.
    func nativeHostOneShot(_ name: String, message: Any, context: WKWebExtensionContext) async throws -> Any {
        let host = try await authorizedHost(name, context: context)
        let connection: NativeHostConnection
        do { connection = try NativeHostConnection(host: host, extensionID: context.uniqueIdentifier) } catch { throw Failure(message: "Failed to start native messaging host.") }
        defer { connection.stop() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            nonisolated(unsafe) var done = false
            let finish: (Result<Any, Error>) -> Void = { result in
                if done { return }; done = true
                switch result {
                case .success(let value): nonisolated(unsafe) let v = value; continuation.resume(returning: v)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            connection.onMessage = { reply in nonisolated(unsafe) let r = reply; finish(.success(r)) }
            connection.onExit = { finish(.failure(Failure(message: "Native host has exited."))) }
            do { try connection.send(message) } catch { finish(.failure(error)) }
            Task { @MainActor in try? await Task.sleep(for: .seconds(15)); finish(.failure(Failure(message: "Native host did not answer."))) }
        }
    }

    /// `connectNative(hôte)` : une connexion qui reste ouverte tant que le programme tourne.
    /// Les messages que l'extension envoie avant que l'hôte soit lancé (et autorisé) sont gardés puis transmis dans l'ordre.
    func nativeHostConnect(_ name: String, port: WKWebExtension.MessagePort, context: WKWebExtensionContext) async throws {
        let queue = PendingMessages()
        port.messageHandler = { message, _ in
            guard let message else { return }
            nonisolated(unsafe) let m = message
            Task { @MainActor in queue.push(m) }
        }
        let host = try await authorizedHost(name, context: context)
        let connection: NativeHostConnection
        do { connection = try NativeHostConnection(host: host, extensionID: context.uniqueIdentifier) } catch { throw Failure(message: "Failed to start native messaging host.") }
        let key = ObjectIdentifier(port)
        nativeHosts.connections[key] = connection
        queue.sink = { message in try? connection.send(message) }
        connection.onMessage = { [weak port] reply in nonisolated(unsafe) let r = reply; port?.sendMessage(r, completionHandler: nil) }
        connection.onExit = { [weak self, weak port] in self?.nativeHosts.connections[key] = nil; port?.disconnect() }
        port.disconnectHandler = { [weak self] _ in Task { @MainActor in self?.nativeHosts.connections[key]?.stop(); self?.nativeHosts.connections[key] = nil } }
    }
}

/// Les messages d'une extension en attente de l'hôte.
@MainActor
final class PendingMessages {
    private var waiting: [Any] = []
    var sink: ((Any) -> Void)? { didSet { if let sink { waiting.forEach(sink); waiting.removeAll() } } }
    func push(_ message: Any) { if let sink { sink(message) } else { waiting.append(message) } }
}
