import Foundation
import OreeAIEngine
import OreeAIProtocol

/// Mesures de l'étape 1, relevées dans ce processus avec le vrai modèle. Sort un tableau Markdown prêt à coller dans Docs/ia-mesures.md.
func runBench(makeEngine: () -> TimedEngine) async {
    let engine = makeEngine()
    let (events, continuation) = AsyncStream.makeStream(of: AIEvent.self)
    let controller = AIController(engine: engine, emit: { continuation.yield($0) })

    func systemFree() -> String {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/memory_pressure"); process.arguments = ["-Q"]
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return "?" }
        process.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").first { $0.contains("free percentage") }.map { String($0.split(separator: ":").last ?? "?").trimmingCharacters(in: .whitespaces) } ?? "?"
    }
    func row(_ step: String, _ detail: String) {
        print(String(format: "| %@ | %@ | %.0f | %.0f | %@ |", step, detail, Memory.footprintMB(), Memory.residentMB(), systemFree()))
    }
    func status() async -> String { let s = await controller.status(); return "\(s.state.rawValue)/\(s.model.rawValue)" }

    print("| étape | durée / détail | empreinte (Mo) | résident (Mo) | mémoire libre système |")
    print("|---|---|---|---|---|")
    row("processus lancé", "—")

    // 0. La vérification SHA-256 seule (1,3 Go lus ; faite une fois par lancement du service, avant le premier chargement).
    var t = Date()
    let verdict = ModelFile.verify(ModelFile.url(for: .qwen35_2B), against: .qwen35_2B)
    row("vérification SHA-256 (\(verdict.rawValue))", String(format: "%.2f s", Date().timeIntervalSince(t)))

    // 1. Réveil à partir du froid : vérification SHA-256 + pré-réveil + ouverture des poids + prompt système (cache KV absent ou présent).
    t = Date()
    await controller.warmUp()
    var d = engine.seconds
    row("froid → chaud (premier réveil)", String(format: "%.2f s total (prewarm %.2f, load %.2f, contexte %.2f)", Date().timeIntervalSince(t),
        d["prewarm"] ?? 0, d["load"] ?? 0, d["startContext"] ?? 0))

    // 2. Trois questions en français, à la suite (le chaud ne doit pas se dégrader).
    var answer = ""
    for question in ["Explique en deux phrases à quoi sert un navigateur web.", "Donne trois conseils pour bien choisir un mot de passe.", "Résume en une phrase ce qu'est un moteur de recherche."] {
        engine.resetGeneration()
        answer = ""
        t = Date()
        _ = await controller.run(AIRunRequest(userText: question))
        for await event in events {
            if case .textDelta(_, let text) = event { answer += text }
            if case .done = event { break }
            if case .error(_, let message) = event { print("| erreur | \(message) | | | |"); return }
        }
        let total = Date().timeIntervalSince(t)
        if let first = engine.firstPieceAt, let last = engine.lastPieceAt, let begin = engine.generateStart, engine.pieces > 1 {
            row("question (chaud)", String(format: "1er jeton après %.2f s · %d jetons · %.1f jetons/s (génération) · %.2f s au total", first - begin, engine.pieces,
                                          Double(engine.pieces - 1) / (last - first), total))
        }
        print("<!-- \(answer.replacingOccurrences(of: "\n", with: " ")) -->")
    }
    print("")

    // 3. Tiède, puis retour au chaud.
    await controller.coolDown()
    row("→ tiède", "état \(await status())")
    t = Date(); await controller.warmUp()
    d = engine.seconds
    row("tiède → chaud", String(format: "%.2f s (contexte %.2f)", Date().timeIntervalSince(t), d["startContext"] ?? 0))

    // 4. Froid (pression mémoire critique simulée), puis retour au chaud : les pages sont encore dans le cache disque de l'OS.
    await controller.memoryPressure(critical: true)
    row("→ froid", "état \(await status())")
    t = Date(); await controller.warmUp()
    d = engine.seconds
    row("froid → chaud (cache disque chaud)", String(format: "%.2f s (prewarm %.2f, load %.2f, contexte %.2f)", Date().timeIntervalSince(t), d["prewarm"] ?? 0, d["load"] ?? 0, d["startContext"] ?? 0))
    await controller.memoryPressure(critical: true)
}
