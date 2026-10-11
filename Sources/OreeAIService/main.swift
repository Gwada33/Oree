import Foundation
import OreeAIEngine
import OreeAIProtocol

// OreeAI — le service IA local d'Orée. Lancé par launchd à la demande (--agent), ou à la main pour essayer :
//   OreeAI --ask "question"     répond en français, en direct, avec les temps
//   OreeAI --bench              relève les mesures de l'étape 1 (voir Docs/ia-mesures.md)
//   OreeAI --client-ping        essaie de se connecter au service : doit être REFUSÉ (ce programme n'est pas Orée)
// Option commune : --mach-name <nom> pour viser un autre service Mach (essais).

let arguments = CommandLine.arguments
func option(_ name: String) -> String? {
    arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
}
let machName = option("--mach-name") ?? OreeAIServiceInfo.machName

// Le cache KV est jetable (il se reconstruit) : dans les caches de l'utilisateur, pas dans ses données.
let kvCache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.nolhan.hyperbrowser/ai-kv", isDirectory: true)

func makeEngine() -> TimedEngine { TimedEngine(LlamaEngine(cacheDirectory: kvCache)) }

// MARK: --client-ping

if arguments.contains("--client-ping") {
    let connection = NSXPCConnection(machServiceName: machName, options: [])
    connection.remoteObjectInterface = NSXPCInterface(with: OreeAIServiceXPC.self)
    connection.resume()
    let answered: Bool = await withCheckedContinuation { continuation in
        final class Once: @unchecked Sendable { let lock = NSLock(); var done = false
            func run(_ body: () -> Void) { lock.lock(); let first = !done; done = true; lock.unlock(); if first { body() } } }
        let once = Once()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.run { continuation.resume(returning: false) } } as? OreeAIServiceXPC
        proxy?.ping { _ in once.run { continuation.resume(returning: true) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { once.run { continuation.resume(returning: false) } }
    }
    print(answered ? "ACCEPTÉ (inattendu)" : "REFUSÉ (attendu)")
    exit(answered ? 1 : 0)
}

// MARK: --ask et --bench (le moteur tourne dans ce processus, sans XPC)

if let at = arguments.firstIndex(of: "--ask"), arguments.indices.contains(at + 1) {
    let engine = makeEngine()
    let (events, continuation) = AsyncStream.makeStream(of: AIEvent.self)
    let controller = AIController(engine: engine, emit: { continuation.yield($0) })
    let start = Date()
    guard await controller.run(AIRunRequest(userText: arguments[at + 1])) else {
        for await event in events { if case .error(_, let message) = event { print("Erreur : \(message)") }; break }
        exit(1)
    }
    for await event in events {
        switch event {
        case .textDelta(_, let text): FileHandle.standardOutput.write(Data(text.utf8))
        case .done: print(""); continuation.finish()
        case .error(_, let message): print("\nErreur : \(message)"); exit(1)
        default: break
        }
    }
    print(String(format: "— %.1f s au total · %.0f Mo d'empreinte", Date().timeIntervalSince(start), Memory.footprintMB()))
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

// Pression mémoire : avertissement → tiède, critique → froid. Le service ne doit jamais être la cause d'un onglet endormi de force.
let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
pressure.setEventHandler { [pressure] in
    let critical = pressure.data.contains(.critical)
    Task { await controller.memoryPressure(critical: critical) }
}
pressure.resume()

// Le service s'arrête seul quand plus personne ne l'utilise (5 minutes sans client ni tâche) ; launchd le relancera au prochain message.
Task {
    var idleTicks = 0
    while true {
        try? await Task.sleep(for: .seconds(5))
        let busy = await controller.isBusy || delegate.connectionCount > 0
        idleTicks = busy ? 0 : idleTicks + 1
        if idleTicks >= 60 { exit(0) }
    }
}
dispatchMain()
