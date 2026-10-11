import Foundation
import OreeAIProtocol

/// Où en est un téléchargement du modèle (vu par le navigateur, qui le fait avec son moteur de téléchargement).
public struct AIDownloadProgress: Equatable, Sendable {
    public var received: Int64
    public var total: Int64?
    public init(received: Int64, total: Int64?) { self.received = received; self.total = total }
}

/// Ce que la barre IA peut faire maintenant, et ce qu'elle dit. Pur : décidé d'après ce que répond le service et l'avancée du téléchargement.
public enum AIAvailability: Equatable, Sendable {
    case connecting
    case unreachable
    case needsModel
    case downloading(AIDownloadProgress)
    case verifying
    case corrupt
    case ready(AIState)

    /// - Parameters:
    ///   - reachable: `nil` tant qu'on ne sait pas, `false` si le service n'a pas répondu.
    ///   - status: dernière réponse du service.
    ///   - download: téléchargement du modèle en cours dans le navigateur (prioritaire sur l'état du fichier).
    public init(reachable: Bool?, status: AIStatus?, download: AIDownloadProgress?) {
        if let download { self = .downloading(download); return }
        guard let reachable else { self = .connecting; return }
        guard reachable else { self = .unreachable; return }
        guard let status else { self = .connecting; return }
        switch status.model {
        case .missing: self = .needsModel
        case .downloading: self = .downloading(AIDownloadProgress(received: 0, total: nil))
        case .verifying: self = .verifying
        case .corrupt: self = .corrupt
        case .ready: self = .ready(status.state)
        }
    }

    public var canAsk: Bool { if case .ready = self { true } else { false } }
    /// Faut-il proposer le bouton « Télécharger le modèle » ?
    public var offersDownload: Bool { self == .needsModel || self == .corrupt }

    /// « 1,3 Go », « 640 Mo ».
    static func size(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f Go", Double(bytes) / 1e9).replacingOccurrences(of: ".", with: ",") : "\(Int((Double(bytes) / 1e6).rounded())) Mo"
    }

    public func line(modelBytes: Int64) -> String {
        switch self {
        case .connecting: "Connexion au service IA…"
        case .unreachable: "Le service IA ne répond pas. Il se lance au premier usage : relancez Orée si le problème reste."
        case .needsModel: "L'IA locale a besoin d'un modèle de \(Self.size(modelBytes)), téléchargé une seule fois et gardé sur ce Mac. Rien ne quitte votre Mac ensuite."
        case .downloading(let progress):
            if let total = progress.total, total > 0 {
                "Téléchargement du modèle : \(Int((Double(progress.received) / Double(total) * 100).rounded())) % (\(Self.size(progress.received)) sur \(Self.size(total)))"
            } else { "Téléchargement du modèle…" }
        case .verifying: "Vérification du modèle…"
        case .corrupt: "Le fichier du modèle est abîmé. Téléchargez-le à nouveau."
        case .ready(let state): state == .cold ? "Prêt (le modèle se réveille en moins d'une seconde)" : "Prêt"
        }
    }
}
