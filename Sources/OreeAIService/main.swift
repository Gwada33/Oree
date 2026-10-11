import Foundation
import OreeAIEngine
import OreeAIProtocol

// OreeAI — le service IA local d'Orée. Lancé par launchd à la demande (--agent), ou à la main pour essayer :
//   OreeAI --ask "question"     répond en français, en direct, avec les temps
//   OreeAI --bench              relève les mesures de l'étape 1 (voir Docs/ia-mesures.md)
//   OreeAI --client-ping        essaie de se connecter au service : REFUSÉ si ce binaire n'est pas signé comme Orée
//   OreeAI --client-ask "q"     pose une question au service par XPC (même condition)
// Option commune : --mach-name <nom> pour viser un autre service Mach (essais).

// Metal garde les poids « résidents » 180 s après le dernier calcul par défaut ; le contrat veut 30 s (état tiède). Doit précéder tout chargement.
setenv("GGML_METAL_RESIDENCY_KEEP_ALIVE_S", "30", 0)

let arguments = CommandLine.arguments
func option(_ name: String) -> String? {
    arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
}
let machName = option("--mach-name") ?? OreeAIServiceInfo.machName

// Le cache KV est jetable (il se reconstruit) : dans les caches de l'utilisateur, pas dans ses données.
let kvCache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.nolhan.hyperbrowser/ai-kv", isDirectory: true)

func makeEngine() -> TimedEngine { TimedEngine(LlamaEngine(cacheDirectory: kvCache)) }

/// Quitte proprement : Metal refuse de se fermer (assertion) tant que le modèle et le contexte ne sont pas libérés.
func quit(_ code: Int32, _ controller: AIController) async -> Never {
    await controller.memoryPressure(critical: true)
    exit(code)
}

// MARK: --client-ping

/// Les fermetures de ce fichier de haut niveau sont liées au fil principal ; XPC les appelle ailleurs (arrêt immédiat en Swift 6).
/// Les deux fonctions d'essai client sont donc isolées ici, hors du fil principal.
final class Once: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func run(_ body: () -> Void) { lock.lock(); let first = !done; done = true; lock.unlock(); if first { body() } }
}

nonisolated func pingService(machName: String) async -> Bool {
    let connection = NSXPCConnection(machServiceName: machName, options: [])
    connection.remoteObjectInterface = NSXPCInterface(with: OreeAIServiceXPC.self)
    connection.resume()
    defer { connection.invalidate() }
    return await withCheckedContinuation { continuation in
        let once = Once()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.run { continuation.resume(returning: false) } } as? OreeAIServiceXPC
        proxy?.ping { _ in once.run { continuation.resume(returning: true) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { once.run { continuation.resume(returning: false) } }
    }
}

if arguments.contains("--client-ping") {
    let answered = await pingService(machName: machName)
    print(answered ? "ACCEPTÉ" : "REFUSÉ")
    exit(0)
}

// MARK: --client-ask : une question au service par XPC (pour l'essai de bout en bout ; accepté seulement si ce binaire est signé comme Orée)

nonisolated func remoteProxy(_ connection: NSXPCConnection) -> OreeAIServiceXPC {
    connection.remoteObjectProxyWithErrorHandler { error in print("Connexion refusée ou coupée : \(error.localizedDescription)"); exit(2) } as! OreeAIServiceXPC
}

if let at = arguments.firstIndex(of: "--client-ask"), arguments.indices.contains(at + 1) {
    final class Printer: NSObject, OreeAIObserverXPC, @unchecked Sendable {
        let finished = DispatchSemaphore(value: 0)
        func event(_ eventJSON: Data) {
            switch AIEvent.decode(eventJSON) {
            case .textDelta(_, let text): FileHandle.standardOutput.write(Data(text.utf8))
            case .done: print(""); finished.signal()
            case .error(_, let message): print("\nErreur : \(message)"); finished.signal()
            default: break
            }
        }
    }
    let printer = Printer()
    let connection = NSXPCConnection(machServiceName: machName, options: [])
    connection.remoteObjectInterface = NSXPCInterface(with: OreeAIServiceXPC.self)
    connection.exportedInterface = NSXPCInterface(with: OreeAIObserverXPC.self)
    connection.exportedObject = printer
    connection.resume()
    let proxy = remoteProxy(connection)
    proxy.subscribe {}
    let request = (try? JSONEncoder().encode(AIRunRequest(userText: arguments[at + 1]))) ?? Data()
    proxy.run(request) {}
    let timedOut: Bool = await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: printer.finished.wait(timeout: .now() + 120) == .timedOut) }
    }
    if timedOut { print("Pas de réponse."); exit(3) }
    exit(0)
}

// MARK: --ask et --bench (le moteur tourne dans ce processus, sans XPC)

if let at = arguments.firstIndex(of: "--ask"), arguments.indices.contains(at + 1) {
    let engine = makeEngine()
    let (events, continuation) = AsyncStream.makeStream(of: AIEvent.self)
    let controller = AIController(engine: engine, emit: { continuation.yield($0) })
    let start = Date()
    guard await controller.run(AIRunRequest(userText: arguments[at + 1])) else {
        for await event in events { if case .error(_, let message) = event { print("Erreur : \(message)") }; break }
        await quit(1, controller)
    }
    for await event in events {
        switch event {
        case .textDelta(_, let text): FileHandle.standardOutput.write(Data(text.utf8))
        case .done: print(""); continuation.finish()
        case .error(_, let message): print("\nErreur : \(message)"); await quit(1, controller)
        default: break
        }
    }
    print(String(format: "— %.1f s au total · %.0f Mo d'empreinte", Date().timeIntervalSince(start), Memory.footprintMB()))
    await quit(0, controller)
}

// --probe <cas.jsonl> [--grammar <g.gbnf>] : sort une ligne JSON par cas avec la sortie brute du modèle (la notation est faite hors du service).
if let at = arguments.firstIndex(of: "--probe"), arguments.indices.contains(at + 1) {
    let engine = LlamaEngine(cacheDirectory: kvCache)
    let grammar = option("--grammar").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
    do {
        try await engine.load(modelAt: ModelFile.url(for: .qwen35_2B))
        try await engine.startContext(systemPrompt: "essai")
        let lines = try String(contentsOfFile: arguments[at + 1], encoding: .utf8).split(separator: "\n")
        for line in lines {
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let id = object["id"] as? String, let prompt = object["prompt"] as? String else { continue }
            let started = Date()
            let output = try await engine.probe(prompt: prompt, grammar: grammar, maxTokens: 300)
            let reply: [String: Any] = ["id": id, "output": output, "seconds": Date().timeIntervalSince(started)]
            print(String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self))
        }
    } catch { print("{\"error\": \"\(error.localizedDescription)\"}") }
    await engine.unload()
    exit(0)
}

if arguments.contains("--bench") {
    await runBench(makeEngine: makeEngine)
    exit(0)
}

// MARK: --agent

guard arguments.contains("--agent") else {
    FileHandle.standardError.write(Data("OreeAI est lancé par launchd (--agent). Essais : --ask \"question\", --bench, --client-ping.\n".utf8))
    exit(64)
}

let hub = AIEventHub()
let controller = AIController(engine: LlamaEngine(cacheDirectory: kvCache), emit: { hub.broadcast($0) })
let delegate = AIListenerDelegate(controller: controller, hub: hub)      // exigence de signature : Orée seul
let listener = NSXPCListener(machServiceName: machName)
listener.delegate = delegate
listener.resume()

// Pression mémoire : avertissement → tiède, critique → froid (une fois la réponse en cours terminée). Le service ne doit jamais être la cause d'un onglet endormi de force.
// Le gestionnaire est créé dans une fonction `nonisolated` : écrit ici, dans le haut niveau de ce fichier, Swift 6 le lie au fil principal et
// le service s'arrêtait net (SIGTRAP) dès le premier événement de pression, donc en pleine réponse sur un Mac de 8 Go.
nonisolated func makeMemoryPressureSource(_ controller: AIController) -> DispatchSourceMemoryPressure {
    let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
    source.setEventHandler { [source] in
        let critical = source.data.contains(.critical)
        Task { await controller.memoryPressure(critical: critical) }
    }
    source.resume()
    return source
}
nonisolated(unsafe) let pressure = makeMemoryPressureSource(controller)

// Le service s'arrête seul quand plus personne ne l'utilise (5 minutes sans client ni tâche) ; launchd le relancera au prochain message.
Task {
    var idleTicks = 0
    while true {
        try? await Task.sleep(for: .seconds(5))
        let busy = await controller.isBusy || delegate.connectionCount > 0
        idleTicks = busy ? 0 : idleTicks + 1
        if idleTicks >= 60 { await quit(0, controller) }
    }
}
dispatchMain()
