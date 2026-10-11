import Foundation

/// Identité du service IA. Même méthode que le téléchargeur : un agent launchd à la demande, un service Mach.
public enum OreeAIServiceInfo {
    public static let machName = "com.nolhan.hyperbrowser.ai"
    /// À incrémenter quand le contrat change de façon incompatible.
    public static let version = "1"
}

/// Messages en JSON `Data` (pas de classes NSSecureCoding) : simple et versionnable, comme `DownloadServiceXPC`.
/// Les réponses de type « accusé » (`reply`) ne portent rien : le résultat réel arrive par `OreeAIObserverXPC`.
@objc public protocol OreeAIServiceXPC {
    /// Précharge les poids (madvise WILLNEED) et restaure le cache KV du prompt système. Répond avec un `AIStatus`.
    func warmUp(reply: @escaping @Sendable (Data) -> Void)
    /// Lance une tâche (`AIRunRequest`). Le flux d'événements arrive par l'observateur ; `reply` confirme seulement la prise en charge.
    func run(_ requestJSON: Data, reply: @escaping @Sendable () -> Void)
    /// Réservé à l'étape 4 : le navigateur renvoie le résultat d'un outil (« OK\n<page>… » ou « ERREUR: … »).
    func toolResult(_ taskID: String, callID: String, text: String, reply: @escaping @Sendable () -> Void)
    func cancel(_ taskID: String, reply: @escaping @Sendable () -> Void)
    /// Sauvegarde le cache KV, libère le contexte, garde les poids en mmap (état tiède).
    func coolDown(reply: @escaping @Sendable () -> Void)
    /// Répond avec un `AIStatus`.
    func status(reply: @escaping @Sendable (Data) -> Void)
    /// Après cet appel, le service pousse `event(_:)` à l'objet exporté par l'appelant.
    func subscribe(reply: @escaping @Sendable () -> Void)
    func ping(reply: @escaping @Sendable (String) -> Void)
}

/// Exporté par le navigateur : reçoit les événements (`AIEvent` en JSON).
@objc public protocol OreeAIObserverXPC {
    func event(_ eventJSON: Data)
}

/// Veille du modèle. Froid : poids en mmap seulement. Chaud : contexte créé. Tiède : cache KV sur disque, contexte libéré.
public enum AIState: String, Codable, Sendable, Equatable {
    case cold, warm, tepid
}

/// Où en est le fichier du modèle (téléchargé à la demande, SHA-256 vérifié avant tout chargement).
public enum AIModelState: String, Codable, Sendable, Equatable {
    case missing, downloading, verifying, ready, corrupt
}

public struct AIStatus: Codable, Sendable, Equatable {
    public var state: AIState
    public var model: AIModelState
    public var version: String
    public init(state: AIState, model: AIModelState, version: String = OreeAIServiceInfo.version) {
        self.state = state; self.model = model; self.version = version
    }
}

public struct AIRunRequest: Codable, Sendable, Equatable {
    public var taskID: String
    public var userText: String
    /// Carte de page (étape 2). Ignorée à l'étape 1.
    public var pageMap: String?
    public init(taskID: String = UUID().uuidString, userText: String, pageMap: String? = nil) {
        self.taskID = taskID; self.userText = userText; self.pageMap = pageMap
    }
}

/// Événements du service vers le navigateur. À l'étape 1 seuls `textDelta`, `done`, `error`, `stateChanged` et `modelProgress` sont émis ;
/// `toolCall` et `needsConfirmation` sont déclarés pour que le navigateur code déjà contre la forme finale.
public enum AIEvent: Codable, Sendable, Equatable {
    case textDelta(taskID: String, text: String)
    case toolCall(taskID: String, callID: String, name: String, argumentsJSON: String)
    case needsConfirmation(taskID: String, callID: String, summary: String)
    case done(taskID: String, answer: String, sources: [String])
    case error(taskID: String?, message: String)
    case stateChanged(AIStatus)
    case modelProgress(received: Int64, total: Int64)

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public static func decode(_ data: Data) -> AIEvent? { try? JSONDecoder().decode(AIEvent.self, from: data) }
}
