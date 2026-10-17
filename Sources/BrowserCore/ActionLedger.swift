import Foundation

/// Le registre d'une tâche de Luciole : ce qui a été demandé, en cours, réussi ou raté, et ce que la page était à ce moment-là.
/// Il dit, AVANT d'exécuter un appel, si c'est utile : un résultat encore valable est réutilisé, une action déjà faite sur la même page n'est pas refaite,
/// un appel qui échoue en boucle est abandonné, et une tâche qui tourne en rond est arrêtée. Rien n'est « réussi » parce qu'il a été demandé :
/// l'état passe à `done` seulement quand l'exécuteur a vérifié le résultat (`finish(ok: true)`).
public struct ActionLedger: Sendable {
    public enum State: Equatable, Sendable { case running, done, failed(Int) }

    public struct Entry: Equatable, Sendable {
        public var step: Int
        public var key: String
        public var call: AgentCall
        public var state: State
        public var result: AgentToolResult?
        public var page: String                 // signature de la page au moment de l'appel
    }

    public enum Verdict: Equatable, Sendable {
        case run                                      // à exécuter
        case reuse(AgentToolResult, step: Int)        // déjà obtenu et toujours valable : rien à refaire
        case refuse(String)                           // inutile ou voué à l'échec : le modèle en est informé
    }

    public static let readOnly: Set<String> = ["search_web", "read_page", "open_url", "search_history", "calculate", "recall"]
    public static let maxFailures = 2
    public static let maxStalled = 3

    public private(set) var entries: [Entry] = []
    private var quiet = 0                             // appels consécutifs qui n'ont rien appris de neuf
    public init() {}

    // MARK: Clé d'un appel

    /// Deux appels qui veulent dire la même chose ont la même clé : arguments triés, requête repliée, adresse normalisée.
    public static func key(for call: AgentCall) -> String {
        guard var args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any] else { return call.name + ":" + call.argumentsJSON }
        if let query = args["query"] as? String { args["query"] = AIRouter.fold(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ") }
        if let url = args["url"] as? String { args["url"] = normalizedURL(url) }
        let data = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])) ?? Data()
        return call.name + ":" + String(decoding: data, as: UTF8.self)
    }

    static func normalizedURL(_ raw: String) -> String {
        guard var parts = URLComponents(string: raw.trimmingCharacters(in: .whitespaces)) else { return raw }
        parts.fragment = nil
        parts.host = parts.host?.lowercased()
        if let host = parts.host, host.hasPrefix("www.") { parts.host = String(host.dropFirst(4)) }
        var path = parts.path; while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        parts.path = path
        return parts.string ?? raw
    }

    // MARK: Avant l'appel

    /// - Parameters:
    ///   - page: la signature de la page affichée maintenant (vide si aucune).
    ///   - currentURL: l'adresse affichée (pour ne pas rouvrir la page où l'on est déjà).
    public func check(_ call: AgentCall, page: String, currentURL: String? = nil) -> Verdict {
        let key = Self.key(for: call)
        let same = entries.filter { $0.key == key }
        let failures = same.reduce(0) { total, entry in if case .failed(let n) = entry.state { return max(total, n) }; return total }      // chaque échec garde le cumul de son appel
        if failures >= Self.maxFailures { return .refuse("Cet appel a déjà échoué \(failures) fois. Change d'approche, ou réponds avec done.") }
        if let running = same.first(where: { $0.state == .running }) { return .refuse("Cet appel est déjà en cours (étape \(running.step)).") }
        if call.name == "open_url", let current = currentURL, Self.key(for: AgentCall(name: "open_url", argumentsJSON: "{\"url\":\"\(call.url ?? "")\"}")) == Self.key(for: AgentCall(name: "open_url", argumentsJSON: "{\"url\":\"\(current)\"}")) {
            return .refuse("Cette page est déjà ouverte. Lis-la au lieu de la rouvrir.")
        }
        guard let done = same.last(where: { $0.state == .done }), let result = done.result else { return .run }
        if Self.readOnly.contains(call.name) {
            // Une lecture dont la source n'a pas bougé : le résultat obtenu vaut toujours. (Une page qui a changé se relit.)
            if call.name != "read_page" || done.page == page { return .reuse(result, step: done.step) }
            return .run
        }
        if call.name == "scroll" { return same.suffix(Self.maxStalled).count == Self.maxStalled && same.suffix(Self.maxStalled).allSatisfy({ $0.page == page }) ? .refuse("Le défilement ne change plus rien : la page est au bout.") : .run }
        // Une action qui change la page : refaite à l'identique sur la même page, elle ferait deux fois la même chose.
        if done.page == page { return .refuse("Déjà fait à l'étape \(done.step), et la page n'a pas changé depuis. Vérifie le résultat ou réponds avec done.") }
        return .run
    }

    // MARK: Pendant et après

    @discardableResult
    public mutating func begin(_ call: AgentCall, step: Int, page: String) -> Int {
        entries.append(Entry(step: step, key: Self.key(for: call), call: call, state: .running, result: nil, page: page))
        return entries.count - 1
    }

    /// Le résultat vérifié : `ok` vient de l'exécuteur (qui a regardé la page), pas de la demande.
    public mutating func finish(_ index: Int, result: AgentToolResult) {
        guard entries.indices.contains(index) else { return }
        let previousFailures = entries.filter { $0.key == entries[index].key }.reduce(0) { if case .failed(let n) = $1.state { return max($0, n) }; return $0 }
        entries[index].result = result
        entries[index].state = result.ok ? .done : .failed(previousFailures + 1)
    }

    /// Un tour de plus : a-t-il appris quelque chose ? (un appel réellement exécuté et réussi, ou une lecture nouvelle).
    public mutating func noteProgress(_ learned: Bool) { quiet = learned ? 0 : quiet + 1 }
    public var isStalled: Bool { quiet >= Self.maxStalled }

    // MARK: Pour le modèle

    /// L'état de la tâche, court : une ligne par étape utile (les doublons réutilisés n'y figurent pas deux fois). Les recherches gardent plus de texte,
    /// parce que le modèle doit pouvoir y revenir ; le reste est résumé.
    public func summary(maxSteps: Int = 6) -> String {
        entries.filter { $0.state != .running }.suffix(maxSteps).map { entry in
            let ok: String
            switch entry.state { case .done: ok = "OK"; case .failed(let n): ok = "ÉCHEC×\(n)"; case .running: ok = "…" }
            let limit = entry.call.name == "search_web" ? 700 : 260
            let text = String((entry.result?.text ?? "").prefix(limit))
            return "\(entry.step). \(entry.call.name) \(entry.call.argumentsJSON) → \(ok) <donnees>\(text)</donnees>"
        }.joined(separator: "\n")
    }

    public func count(_ state: (State) -> Bool) -> Int { entries.filter { state($0.state) }.count }
}

private extension AgentCall {
    var url: String? { ((try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any])?["url"] as? String }
}
