import Foundation

/// Les treize poses de Luciole, la mascotte du panneau IA (cf. la fiche de design « Luciole »).
public enum LucioleState: String, CaseIterable, Sendable {
    case idle, read, think, write, act, wait, ask, happy, sleep, load, wake, err, off

    /// La pose d'après ce que fait le panneau. Pur, donc testé.
    /// - `running`: une tâche est en cours ; `streaming`: du texte est déjà arrivé pour cette tâche.
    public static func pose(availability: AIAvailability, running: Bool, streaming: Bool, failed: Bool) -> LucioleState {
        switch availability {
        case .connecting: return .wake
        case .unreachable: return .off
        case .needsModel: return .sleep
        case .downloading, .verifying: return .load
        case .corrupt: return .err
        case .ready:
            if failed { return .err }
            if running { return streaming ? .write : .think }
            return .idle
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
