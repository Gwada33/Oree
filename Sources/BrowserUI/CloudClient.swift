import Foundation
import BrowserCore
import BrowserStorage

/// Un tour de conversation avec un fournisseur d'IA (Mistral, Groq, LM Studio) : envoie la conversation (donc le contenu de la page lue) à son adresse, en HTTPS,
/// avec la clé du Trousseau. Rien n'est envoyé tant que la personne n'a pas choisi ce fournisseur dans Réglages › Assistant IA.
///
/// Une requête au modèle ne fait rien dans le navigateur : la relancer ne peut pas doubler une action. Les erreurs passagères (429, serveur occupé, réseau) sont donc
/// relancées avec une attente qui double, plus longue si le fournisseur le demande (`Retry-After`), un nombre d'essais borné et une annulation possible à tout moment ;
/// une erreur définitive (clé refusée, requête invalide) n'est jamais relancée. Un « attendez » vaut pour tous les tours qui suivent (`RateLimitGate`).
struct CloudClient: Sendable {
    struct Failure: Error, LocalizedError { var message: String; var errorDescription: String? { message } }

    let provider: AIProvider
    let model: String
    let endpoint: URL
    var policy = RetryPolicy()
    private var keychain: CloudKeychain { CloudKeychain(provider) }

    private static let gates = LockedGates()
    private final class LockedGates: @unchecked Sendable {
        private let lock = NSLock(); private var gates: [AIProvider: RateLimitGate] = [:]
        func gate(_ provider: AIProvider) -> RateLimitGate { lock.lock(); defer { lock.unlock() }; if let g = gates[provider] { return g }; let g = RateLimitGate(); gates[provider] = g; return g }
    }

    /// Renvoie le texte lu par la boucle d'agent (un appel d'outil devient une ligne JSON, un texte reste un texte). La réponse arrive en flux : `onText` reçoit le
    /// texte écrit jusque-là au fur et à mesure (pour l'afficher mot à mot) ; un appel d'outil, lui, n'est utilisable qu'une fois ses arguments complets.
    /// `onWait` est appelé quand une attente commence (secondes) : l'interface peut dire « limite de débit, nouvel essai dans N s ».
    func complete(_ request: ModelRequest,
                  onText: (@MainActor @Sendable (_ text: String, _ thinking: String) -> Void)? = nil,
                  onWait: (@MainActor @Sendable (_ seconds: Int) -> Void)? = nil) async throws -> String {
        let key = keychain.load()
        if provider.isCloud, key == nil { throw Failure(message: "Aucune clé \(provider.displayName) : ajoutez-la dans Réglages › Assistant IA.") }
        // LM Studio tourne sur ce Mac avec un modèle que la machine fait tourner elle-même : bien plus lent qu'un serveur en nuage.
        var http = URLRequest(url: endpoint, timeoutInterval: provider == .lmstudio ? 180 : 45)
        http.httpMethod = "POST"
        if let key { http.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        http.httpBody = GroqChat.requestBody(request, model: model, stream: true)

        let gate = Self.gates.gate(provider)
        var attempt = 0
        var waited = 0.0
        while true {
            try Task.checkCancellation()
            // Un autre tour vient d'apprendre que le fournisseur limite le débit : on attend avec lui, sans rien envoyer.
            let queued = gate.wait()
            if queued > 0 { await onWait?(Int(queued.rounded(.up))); try await Task.sleep(for: .seconds(queued)); waited += queued }
            attempt += 1
            AIUsageMeter.shared.record { $0.requests += 1; $0.contextChars += http.httpBody?.count ?? 0; if attempt > 1 { $0.retries += 1 } }

            var status: Int?
            var headerWait: Double?
            var hint: Double?
            var failure = "\(provider.displayName) n'a pas répondu."
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: http)
                let reply = response as? HTTPURLResponse
                status = reply?.statusCode ?? 0
                headerWait = RetryAfter.seconds(from: reply?.value(forHTTPHeaderField: "retry-after"))
                    ?? RetryAfter.duration(reply?.value(forHTTPHeaderField: "x-ratelimit-reset-tokens") ?? "")
                    ?? RetryAfter.duration(reply?.value(forHTTPHeaderField: "x-ratelimit-reset-requests") ?? "")
                if (200..<300).contains(status ?? 0) {
                    var assembler = ChatStreamAssembler()
                    for try await line in bytes.lines {
                        if assembler.feed(line: line) != nil, let onText { let shown = assembler.displayText, thought = assembler.reasoning; await onText(shown, thought) }
                    }
                    if let used = assembler.usage { AIUsageMeter.shared.record { $0.promptTokens += used.prompt; $0.completionTokens += used.completion } }
                    let parsed = assembler.reply(provider: provider)
                    if case .failure(let message, _) = parsed { failure = message; hint = 0.4; status = nil }           // un flux vide ou coupé : un accident à relancer
                    else if let text = GroqChat.agentText(parsed) { return assembler.wasCutShort && !text.hasPrefix("{") ? text + " […]" : text }
                } else {
                    var data = Data()
                    for try await byte in bytes { data.append(byte) }
                    let parsed = GroqChat.parse(status: status ?? 0, body: data, retryAfterHeader: nil, provider: provider)
                    if case .failure(let message, let retry) = parsed { failure = message; if status == 400 { hint = retry } }     // appel d'outil mal écrit : relancé aussitôt
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw CancellationError() }
            catch { status = nil; failure = "\(provider.displayName) est injoignable : \(error.localizedDescription)" }

            let random = Double.random(in: 0...1)
            switch policy.decide(status: status, attempt: attempt, retryAfter: headerWait, hint: hint, waited: waited, random: random) {
            case .retry(let delay):
                if status == 429 { gate.hold(for: delay) }
                await onWait?(Int(delay.rounded(.up)))
                try await Task.sleep(for: .seconds(delay))
                waited += delay
            case .giveUp(let reason):
                AIUsageMeter.shared.record { $0.failures += 1 }
                let tail = status == 429 ? " Réessayez dans un instant : la tâche repartira de là où elle en était." : (reason == "erreur définitive" ? "" : " (\(reason))")
                throw Failure(message: failure + tail)
            }
        }
    }
}
