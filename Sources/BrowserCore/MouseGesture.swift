import Foundation
import CoreGraphics

/// Gestes de souris : bouton droit enfoncé, on dessine un trait (gauche, droite, haut, bas, ou une suite), on relâche : l'action associée s'exécute.
/// Ce fichier ne fait que reconnaître le trait : les points reçus deviennent une suite de directions (« DR » = bas puis droite). Les petits tremblements ne comptent pas.
public enum MouseGesture {
    public enum Direction: Character, Sendable { case left = "L", right = "R", up = "U", down = "D" }

    /// Distance (en points) à partir de laquelle un mouvement devient une direction, et mouvement total sous lequel c'est un simple clic droit (menu contextuel).
    public static let segment: CGFloat = 28
    public static let clickTolerance: CGFloat = 10

    public struct Result: Equatable, Sendable {
        public var code: String            // « LD », « R »… ; vide si rien de reconnu
        public var isGesture: Bool         // le pointeur a assez bougé pour que ce soit un geste, pas un clic droit
    }

    /// `points` : la trace, dans un repère où y croît vers le HAUT (celui d'AppKit pour une vue non retournée).
    public static func recognize(_ points: [CGPoint], segment: CGFloat = MouseGesture.segment) -> Result {
        guard let first = points.first else { return Result(code: "", isGesture: false) }
        let travelled = points.dropFirst().reduce(0) { max($0, hypot($1.x - first.x, $1.y - first.y)) }
        guard travelled > clickTolerance else { return Result(code: "", isGesture: false) }
        var code = "", anchor = first
        for point in points.dropFirst() {
            let dx = point.x - anchor.x, dy = point.y - anchor.y
            guard max(abs(dx), abs(dy)) >= segment else { continue }
            let direction: Direction = abs(dx) >= abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .up : .down)
            if code.last != direction.rawValue { code.append(direction.rawValue) }
            anchor = point
        }
        return Result(code: String(code.prefix(4)), isGesture: true)
    }

    /// Ce que fait chaque geste : les plus courants sont les plus simples (comme dans Opera et Vivaldi).
    public enum Action: String, CaseIterable, Sendable {
        case back, forward, newTab, closeTab, reload, scrollTop, scrollBottom, previousTab, nextTab, reopenTab

        public var label: String {
            switch self {
            case .back: "Page précédente"; case .forward: "Page suivante"; case .newTab: "Nouvel onglet"; case .closeTab: "Fermer l'onglet"; case .reload: "Recharger"
            case .scrollTop: "Haut de la page"; case .scrollBottom: "Bas de la page"; case .previousTab: "Onglet précédent"; case .nextTab: "Onglet suivant"; case .reopenTab: "Rouvrir l'onglet fermé"
            }
        }
    }

    public static let bindings: [String: Action] = [
        "L": .back, "R": .forward, "D": .newTab, "DR": .closeTab, "UD": .reload, "U": .scrollTop, "DU": .scrollBottom, "UL": .previousTab, "UR": .nextTab, "DL": .reopenTab,
    ]

    public static func action(for code: String) -> Action? { bindings[code] }
}
