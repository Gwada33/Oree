import Foundation

/// Ce que le panneau IA peut faire maintenant. Décidé d'après le fournisseur choisi (clé présente, serveur joignable), jamais d'après un modèle embarqué.
public enum AIAvailability: Equatable, Sendable {
    case connecting
    case unreachable
    case ready

    public var canAsk: Bool { self == .ready }
}

/// Les treize poses de Luciole, la mascotte du panneau IA (cf. la fiche de design « Luciole »).
public enum LucioleState: String, CaseIterable, Sendable {
    case idle, read, think, write, act, wait, ask, happy, sleep, load, wake, err, off

    /// La pose d'après ce que fait le panneau. Pur, donc testé.
    /// - `running`: une tâche est en cours ; `streaming`: du texte est déjà arrivé pour cette tâche.
    public static func pose(availability: AIAvailability, running: Bool, streaming: Bool, failed: Bool) -> LucioleState {
        switch availability {
        case .connecting: return .wake
        case .unreachable: return .off
        case .ready:
            if failed { return .err }
            if running { return streaming ? .write : .think }
            return .idle
        }
    }

    /// La pose qui correspond à un événement réel de la tâche : une requête part (réflexion), le fournisseur fait patienter (attente), une recherche (lecture),
    /// une ouverture de page (action), une saisie (écriture)… Rien n'est simulé : sans événement, la pose ne change pas.
    public static func pose(for event: AgentEvent) -> LucioleState {
        switch event {
        case .thinking: return .think
        case .waitingForProvider: return .wait
        case .tool(let name):
            switch name {
            case "search_web", "read_page": return .read
            case "type", "fill_form": return .write
            case "ask_user": return .ask
            case "scroll": return .read
            default: return .act
            }
        case .finished(let reason):
            switch reason {
            case .done: return .happy
            case .failed: return .err
            case .stepCap, .stalled: return .wait
            case .cancelled: return .idle
            }
        }
    }
}

/// La largeur du panneau : 380 pt par défaut, de 320 à 520 pt à la poignée ; sous 900 pt de fenêtre, il passe par-dessus la page.
public enum AIPanelMetrics {
    public static let defaultWidth: Double = 380
    public static let minWidth: Double = 320
    public static let maxWidth: Double = 520
    public static let overlayBelow: Double = 900

    public static func clamp(_ width: Double) -> Double { min(max(width, minWidth), maxWidth) }
    /// Le panneau pousse la page seulement si la fenêtre est assez large ; sinon il la recouvre.
    public static func pushesPage(windowWidth: Double) -> Bool { windowWidth >= overlayBelow }
}
