import Foundation

/// Où en est Luciole quand elle vit DANS la page. Une seule machine à états : chaque état décide de sa place, de sa pose et des surfaces visibles.
public enum LucioleStage: String, CaseIterable, Sendable {
    case rest, call, selection, answer, action, validation, question, protected

    public struct Inputs: Equatable, Sendable {
        public var isOpen: Bool                 // ⌘J : Luciole est appelée
        public var pageProtected: Bool          // réglages d'Orée, paiement, mots de passe
        public var hasSelection: Bool           // au moins trois mots sélectionnés, sans saisie en cours
        public var running: Bool                // une tâche est en cours
        public var actingOnPage: Bool           // la tâche a déjà agi sur la page (clic, saisie…)
        public var pendingConfirm: Bool
        public var pendingQuestion: Bool
        public var hasAnswer: Bool              // la dernière réponse est affichée
        public init(isOpen: Bool = false, pageProtected: Bool = false, hasSelection: Bool = false, running: Bool = false, actingOnPage: Bool = false,
                    pendingConfirm: Bool = false, pendingQuestion: Bool = false, hasAnswer: Bool = false) {
            self.isOpen = isOpen; self.pageProtected = pageProtected; self.hasSelection = hasSelection; self.running = running; self.actingOnPage = actingOnPage
            self.pendingConfirm = pendingConfirm; self.pendingQuestion = pendingQuestion; self.hasAnswer = hasAnswer
        }
    }

    /// Une validation ou une question passent avant tout (c'est la sécurité), puis l'action, la réponse, la sélection, l'appel. Fermée, elle dort.
    public static func stage(for i: Inputs) -> LucioleStage {
        guard i.isOpen else { return i.hasSelection && !i.pageProtected && i.running == false ? .selection : .rest }
        if i.pageProtected { return .protected }
        if i.pendingConfirm { return .validation }
        if i.pendingQuestion { return .question }
        if i.running, i.actingOnPage { return .action }
        if i.hasAnswer || i.running { return .answer }
        if i.hasSelection { return .selection }
        return .call
    }

    /// La pose de la mascotte dans cet état (la fiche : repos → sleep, appel → idle, sélection → read, réponse → write, action → act, validation → wait, question → ask).
    public var pose: LucioleState {
        switch self {
        case .rest: .sleep
        case .call: .idle
        case .selection: .read
        case .answer: .write
        case .action: .act
        case .validation: .wait
        case .question: .ask
        case .protected: .off
        }
    }

    /// La taille de la mascotte, en points : 28 au repos (barre d'outils), 54 dans la capsule, 40-44 ailleurs dans la page.
    public var mascotSize: Double {
        switch self {
        case .rest, .protected: 28
        case .call: 54
        default: 42
        }
    }
}
