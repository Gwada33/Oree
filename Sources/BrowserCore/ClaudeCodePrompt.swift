import Foundation

/// Parler à Claude Code (`claude -p`) : le programme ne fait pas d'appels d'outils au format OpenAI. La conversation de Luciole (consigne, page, échanges, résultats d'outils)
/// devient donc un texte, et les outils sont décrits dans la consigne ; Claude répond par des lignes JSON `{"tool":"click","ref":"@e3"}` ou par du texte, que `AgentParser` sait lire.
/// Pur : rien ici ne lance de processus.
public enum ClaudeCodePrompt {
    /// Ce que dit Claude pour qu'il reste Luciole et réponde dans le format de la boucle d'agent.
    public static func system(for request: ModelRequest) -> String {
        let base = request.messages.first(where: { $0.role == .system })?.content ?? GroqChat.system
        var lines = [base, "",
                     "Tu n'as AUCUN outil à toi : tu n'agis qu'avec ceux de la liste ci-dessous, en répondant avec UN OU PLUSIEURS objets JSON, un par ligne, sans aucun texte autour :",
                     #"{"tool":"nom","argument":"valeur"}"#,
                     #"Pour répondre à la personne, écris simplement ta réponse (Markdown simple) ou {"tool":"done","answer":"…"}. Ne mélange jamais du texte et un appel d'outil."#,
                     "", "Outils permis :"]
        lines += toolLines(request.tools)
        return lines.joined(separator: "\n")
    }

    /// Une ligne par outil, tirée du contrat des outils de `GroqChat` : nom, arguments avec leur type (ou leurs valeurs permises), description, et un exemple d'appel exact.
    /// Sans les types ni l'exemple, Claude devinait mal (un calcul sans « expression », un défilement « down » répété au lieu de « bottom »).
    static func toolLines(_ wanted: [String]) -> [String] {
        let allowed = Set(wanted + ["done"])
        return GroqChat.tools.compactMap { tool -> String? in
            guard let function = tool["function"] as? [String: Any], let name = function["name"] as? String, allowed.contains(name) else { return nil }
            let schema = function["parameters"] as? [String: Any] ?? [:]
            let properties = schema["properties"] as? [String: Any] ?? [:]
            let required = Set(schema["required"] as? [String] ?? [])
            let described = properties.keys.sorted().map { key -> String in
                let spec = properties[key] as? [String: Any] ?? [:]
                let kind: String
                if let values = spec["enum"] as? [String] { kind = values.joined(separator: "|") }
                else { switch spec["type"] as? String { case "boolean": kind = "vrai/faux"; case "number": kind = "nombre"; case "object": kind = "objet"; default: kind = "texte" } }
                return "\(key)\(required.contains(key) ? "" : "?"): \(kind)"
            }
            var line = "- \(name)(\(described.joined(separator: ", "))) : \(function["description"] as? String ?? "")"
            let example = properties.keys.sorted().filter { required.contains($0) }.map { key -> String in
                let spec = properties[key] as? [String: Any] ?? [:]
                let sample: String
                if let values = spec["enum"] as? [String], let first = values.last { sample = "\"\(first)\"" }
                else if spec["type"] as? String == "object" { sample = #"{"@e3":"valeur"}"# }
                else if spec["type"] as? String == "boolean" { sample = "true" }
                else if spec["type"] as? String == "number" { sample = "2" }
                else { sample = "\"…\"" }
                return "\"\(key)\":\(sample)"
            }
            if !described.isEmpty { line += " Exemple : {\"tool\":\"\(name)\"\(example.isEmpty ? "" : "," + example.joined(separator: ","))}" }
            return line
        }
    }

    /// La conversation en texte : les messages utilisateur, les appels de Luciole et les résultats des outils, dans l'ordre.
    public static func conversation(_ request: ModelRequest) -> String {
        var blocks: [String] = []
        for message in request.messages where message.role != .system {
            switch message.role {
            case .user: blocks.append("Utilisateur :\n\(message.content)")
            case .assistant:
                if message.calls.isEmpty { blocks.append("Luciole :\n\(message.content)") }
                else { blocks.append("Luciole (appels d'outils) :\n" + message.calls.map { #"{"tool":"\#($0.call.name)",\#(argumentsFragment($0.call.argumentsJSON))}"# }.joined(separator: "\n")) }
            case .tool: blocks.append("Résultat de l'outil :\n\(message.content)")
            case .system: break
            }
        }
        return blocks.joined(separator: "\n\n") + "\n\nÀ toi, Luciole :"
    }

    /// `{"ref":"@e3"}` → `"ref":"@e3"` (les arguments d'un appel, sans leurs accolades, pour les glisser dans `{"tool":…}`).
    static func argumentsFragment(_ json: String) -> String {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return "" }
        let inner = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? #""_":true"# : String(inner)
    }

    // MARK: Réponse

    public struct Reply: Equatable, Sendable {
        public var text: String
        public var inputTokens: Int
        public var outputTokens: Int
        public var isError: Bool
    }

    /// La sortie JSON de `claude -p --output-format json` : le texte de la réponse et les jetons comptés. Une erreur (non connecté, limite atteinte) est reconnue.
    public static func parse(output: String) -> Reply? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let object = (try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8))) as? [String: Any] else { return nil }
        let usage = object["usage"] as? [String: Any] ?? [:]
        func number(_ key: String) -> Int { (usage[key] as? Int) ?? 0 }
        return Reply(text: (object["result"] as? String) ?? "", inputTokens: number("input_tokens") + number("cache_read_input_tokens") + number("cache_creation_input_tokens"),
                     outputTokens: number("output_tokens"), isError: (object["is_error"] as? Bool) ?? false)
    }

    /// Le message à montrer quand Claude Code répond par une erreur.
    public static func message(forError text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("not logged in") || lower.contains("/login") { return "Claude Code n'est pas connecté : ouvrez le Terminal, tapez « claude » puis « /login »." }
        if lower.contains("limit") || lower.contains("quota") || lower.contains("usage") { return "Votre limite d'utilisation de Claude est atteinte : \(text.prefix(160)) Choisissez un autre fournisseur en attendant." }
        return "Claude Code a répondu par une erreur : \(text.prefix(200))"
    }
}


/// Où se trouve le programme `claude` : le chemin forcé (`HB_CLAUDE_PATH`, essais), puis les emplacements d'installation habituels. Une app lancée depuis le Finder n'a pas le PATH du Terminal.
public enum ClaudeCodeLocator {
    public static func executable(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory(),
                                  isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        var candidates = [environment["HB_CLAUDE_PATH"], "/opt/homebrew/bin/claude", "/usr/local/bin/claude", home + "/.claude/local/claude", home + "/.local/bin/claude", home + "/.npm-global/bin/claude"].compactMap { $0 }
        if let path = environment["PATH"] { candidates += path.split(separator: ":").map { $0 + "/claude" } }
        return candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }
}
