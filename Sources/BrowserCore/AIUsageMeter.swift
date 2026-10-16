import Foundation

/// Ce que coûte une tâche de Luciole : requêtes, jetons (comptés par le fournisseur), taille du contexte envoyé, recherches, lectures de page, nouvelles tentatives.
/// Les chiffres viennent de ce qui s'est réellement passé (jamais d'une estimation) ; `contextChars` est la taille brute des requêtes, en caractères.
public final class AIUsageMeter: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        public var requests = 0, retries = 0, failures = 0
        public var promptTokens = 0, completionTokens = 0, contextChars = 0
        public var searches = 0, searchesCached = 0, pageReads = 0, pageReadsCached = 0, actionsSkipped = 0
        public init() {}
        public var summary: String {
            "requêtes=\(requests) relances=\(retries) échecs=\(failures) jetons_entrée=\(promptTokens) jetons_sortie=\(completionTokens) contexte_car=\(contextChars) "
            + "recherches=\(searches)(+\(searchesCached) en cache) lectures=\(pageReads)(+\(pageReadsCached) en cache) actions_évitées=\(actionsSkipped)"
        }
    }

    public static let shared = AIUsageMeter()
    private let lock = NSLock()
    private var value = Snapshot()

    public init() {}
    public func record(_ change: (inout Snapshot) -> Void) { lock.lock(); change(&value); lock.unlock() }
    public var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return value }
    public func reset() { lock.lock(); value = Snapshot(); lock.unlock() }
}
