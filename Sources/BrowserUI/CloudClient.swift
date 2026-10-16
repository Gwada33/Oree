import Foundation
import BrowserCore
import BrowserStorage

/// Un tour de conversation avec un fournisseur en nuage (Mistral, Groq) : envoie la consigne et la carte de page (donc le contenu de la page lue) à son adresse, en HTTPS,
/// avec la clé du Trousseau. Rien n'est envoyé tant que la personne n'a pas choisi ce fournisseur dans Réglages › Assistant IA.
struct CloudClient: Sendable {
    struct Failure: Error, LocalizedError { var message: String; var errorDescription: String? { message } }

    let provider: AIProvider
    let model: String
    let endpoint: URL
    private var keychain: CloudKeychain { CloudKeychain(provider) }

    /// Renvoie le texte lu par la boucle d'agent (un appel d'outil devient une ligne JSON, un texte reste un texte). La réponse arrive en flux : `onText` reçoit le
    /// texte écrit jusque-là au fur et à mesure (pour l'afficher mot à mot) ; un appel d'outil, lui, n'est utilisable qu'une fois ses arguments complets.
    func complete(prompt: String, onText: (@MainActor @Sendable (_ text: String, _ thinking: String) -> Void)? = nil) async throws -> String {
        let key = keychain.load()
        if provider.isCloud, key == nil { throw Failure(message: "Aucune clé \(provider.displayName) : ajoutez-la dans Réglages › Assistant IA.") }
        // LM Studio tourne sur ce Mac avec un modèle que la machine fait tourner elle-même : bien plus lent qu'un serveur en nuage.
        var request = URLRequest(url: endpoint, timeoutInterval: provider == .lmstudio ? 180 : 45)
        request.httpMethod = "POST"
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = GroqChat.requestBody(prompt: prompt, model: model, stream: true)
        for attempt in 0..<4 {
            try Task.checkCancellation()
            AIUsageMeter.shared.record { $0.requests += 1; $0.contextChars += request.httpBody?.count ?? 0; if attempt > 0 { $0.retries += 1 } }
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let reply: GroqChat.Reply
            if (200..<300).contains(status) {
                var assembler = ChatStreamAssembler()
                for try await line in bytes.lines {
                    if assembler.feed(line: line) != nil, let onText { let shown = assembler.displayText, thought = assembler.reasoning; await onText(shown, thought) }
                }
                reply = assembler.reply(provider: provider)
                if let used = assembler.usage { AIUsageMeter.shared.record { $0.promptTokens += used.prompt; $0.completionTokens += used.completion } }
            } else {
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                reply = GroqChat.parse(status: status, body: data, retryAfterHeader: http?.value(forHTTPHeaderField: "retry-after"), provider: provider)
            }
            if case .failure(let message, let retry) = reply {
                // Limite de débit : on attend ce que le fournisseur demande (20 s au plus) et on réessaie, au lieu d'abandonner la tâche.
                if let retry, attempt < 3, retry <= 20 { try await Task.sleep(for: .seconds(retry + 0.5)); continue }
                if status == 200, attempt < 3 { continue }              // un flux vide ou coupé : un nouvel essai
                AIUsageMeter.shared.record { $0.failures += 1 }
                throw Failure(message: message)
            }
            if let text = GroqChat.agentText(reply) { return text }
        }
        throw Failure(message: "\(provider.displayName) n'a pas répondu.")
    }
}
