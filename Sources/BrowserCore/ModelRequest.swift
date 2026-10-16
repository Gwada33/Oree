import Foundation

/// Un message de la conversation avec le modèle. La conversation est gardée en entier d'un tour à l'autre (au lieu d'être réécrite à chaque tour) :
/// le début (consignes, outils, tâche) ne change pas, et ce qui est périmé — une ancienne version de la page — est remplacé au lieu de s'accumuler.
public struct ChatMessage: Equatable, Sendable {
    public enum Role: String, Sendable { case system, user, assistant, tool }
    public var role: Role
    public var content: String
    /// Pour un message du modèle : les appels d'outils qu'il a faits (avec leur identifiant).
    public var calls: [(id: String, call: AgentCall)] = []
    /// Pour un résultat d'outil : l'identifiant de l'appel auquel il répond.
    public var callID: String?
    /// Le message qui porte la page affichée (un seul à la fois dans la conversation).
    public var isPage = false

    public init(role: Role, content: String, calls: [(id: String, call: AgentCall)] = [], callID: String? = nil, isPage: Bool = false) {
        self.role = role; self.content = content; self.calls = calls; self.callID = callID; self.isPage = isPage
    }
    public static func == (a: ChatMessage, b: ChatMessage) -> Bool {
        a.role == b.role && a.content == b.content && a.callID == b.callID && a.isPage == b.isPage && a.calls.map { "\($0.id)\($0.call.name)\($0.call.argumentsJSON)" } == b.calls.map { "\($0.id)\($0.call.name)\($0.call.argumentsJSON)" }
    }
}

/// Une requête au modèle : la conversation, les outils permis (seulement ceux-là sont envoyés) et la limite de sortie.
public struct ModelRequest: Equatable, Sendable {
    public var messages: [ChatMessage]
    public var tools: [String]
    public var maxTokens: Int
    public init(messages: [ChatMessage], tools: [String], maxTokens: Int) { self.messages = messages; self.tools = tools; self.maxTokens = maxTokens }

    /// Le texte de la dernière consigne de l'utilisateur (pour les traces).
    public var lastUserText: String { messages.last { $0.role == .user }?.content ?? "" }
}
