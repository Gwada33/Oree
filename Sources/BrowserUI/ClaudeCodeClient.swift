import Foundation
import BrowserCore

/// Luciole qui répond par Claude, via le programme `claude` (Claude Code) déjà installé et connecté sur ce Mac : pas de clé à donner à Orée, la connexion est celle de Claude Code,
/// et chaque réponse compte dans la limite de l'abonnement. À usage personnel : ce n'est pas un moyen de distribuer une app qui s'appuierait sur l'abonnement de quelqu'un d'autre.
///
/// Un processus par tour (sans session gardée) : la conversation de Luciole est renvoyée en entier à chaque fois, comme avec une API. Mesuré le 22 octobre 2026 : ~3,9 s de bout en bout
/// pour une question simple avec Haiku (2 s pour le modèle, le reste est le démarrage du programme), ~500 jetons d'entrée avec `--setting-sources project`
/// (sans cela, les réglages, mémoires et hooks de l'utilisateur ajoutent ~900 jetons à chaque appel).
struct ClaudeCodeClient: Sendable {
    struct Failure: Error, LocalizedError { var message: String; var errorDescription: String? { message } }

    let model: String
    var timeout: TimeInterval = 90

    static func executable() -> URL? { ClaudeCodeLocator.executable() }

    func complete(_ request: ModelRequest) async throws -> String {
        guard let executable = Self.executable() else { throw Failure(message: "Claude Code est introuvable sur ce Mac : installez-le (https://claude.com/claude-code), puis tapez « claude » dans le Terminal pour vous connecter.") }
        let system = ClaudeCodePrompt.system(for: request), prompt = ClaudeCodePrompt.conversation(request)
        AIUsageMeter.shared.record { $0.requests += 1; $0.contextChars += system.utf8.count + prompt.utf8.count }
        let output = try await run(executable: executable, system: system, prompt: prompt)
        guard let reply = ClaudeCodePrompt.parse(output: output) else {
            AIUsageMeter.shared.record { $0.failures += 1 }
            throw Failure(message: "Claude Code n'a pas répondu comme prévu : \(output.prefix(160))")
        }
        AIUsageMeter.shared.record { $0.promptTokens += reply.inputTokens; $0.completionTokens += reply.outputTokens }
        if reply.isError { AIUsageMeter.shared.record { $0.failures += 1 }; throw Failure(message: ClaudeCodePrompt.message(forError: reply.text)) }
        return reply.text
    }

    private func run(executable: URL, system: String, prompt: String) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-p", "--model", model, "--tools", "", "--no-session-persistence", "--output-format", "json", "--setting-sources", "project",
                             "--disable-slash-commands", "--strict-mcp-config", "--system-prompt", system]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oree-claude", isDirectory: true)       // un dossier vide : aucun réglage de projet à charger
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", NSHomeDirectory() + "/.local/bin", environment["PATH"] ?? ""].joined(separator: ":")
        process.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = errors

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try process.run() } catch { continuation.resume(throwing: Failure(message: "Claude Code n'a pas pu démarrer : \(error.localizedDescription)")); return }
                    input.fileHandleForWriting.write(Data(prompt.utf8)); try? input.fileHandleForWriting.close()
                    let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit(); killer.cancel()
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                    let text = String(decoding: data, as: UTF8.self)
                    if text.isEmpty { continuation.resume(throwing: Failure(message: "Claude Code n'a rien répondu\(timeout > 0 && process.terminationReason == .uncaughtSignal ? " (trop long, arrêté)" : "") : \(String(decoding: errorData, as: UTF8.self).prefix(160))")) }
                    else { continuation.resume(returning: text) }
                }
            }
        } onCancel: { if process.isRunning { process.terminate() } }
    }
}
