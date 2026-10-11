import Foundation

/// Ce que le contrôleur attend d'un moteur de génération. `LlamaEngine` (llama.cpp) l'implémente dans `OreeAIService` ;
/// les tests utilisent un faux moteur, ce qui évite de charger 1,3 Go pour vérifier le protocole et les états.
public protocol AIEngine: Sendable {
    /// Ouvre les poids (mmap). Ne crée pas de contexte.
    func load(modelAt url: URL) async throws
    /// Pré-réveil : demande à l'OS de relire les poids en tâche de fond (madvise WILLNEED).
    func prewarm() async
    /// Crée le contexte et y met le prompt système (depuis le cache KV sur disque s'il existe, sinon en le calculant puis en l'écrivant).
    func startContext(systemPrompt: String) async throws
    /// Libère le contexte (et la mémoire GPU qui va avec) ; les poids restent ouverts.
    func stopContext() async
    /// Ferme aussi les poids : l'OS peut reprendre les pages.
    func unload() async
    /// Génère la réponse à `user`, morceau de texte par morceau. Annuler la tâche qui lit le flux arrête la génération.
    func generate(user: String, maxTokens: Int) -> AsyncThrowingStream<String, Error>
}

public enum AIPrompts {
    /// Prompt système de l'étape 1 (sans outils). Court exprès : il est mis en cache (KV) une fois pour toutes.
    public static let system = "Tu es l'assistant intégré à Orée, un navigateur web. Réponds toujours en français, de façon claire et concise."
}
