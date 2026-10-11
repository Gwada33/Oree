import Foundation

/// Les « mains » de l'IA (étape 3 de Docs/ia.md) : ce que le modèle peut demander, et les règles qui décident, avant tout geste,
/// si on refuse, si on demande à la personne, ou si on peut agir. Pur : testé sans page.
public enum AIAction: Equatable, Sendable {
    case click(ref: Int)
    case type(ref: Int, text: String, submit: Bool)
    case select(ref: Int, option: String)
    case scroll(direction: String)
    case fillForm(fields: [(ref: Int, value: String)])

    public static func == (a: AIAction, b: AIAction) -> Bool {
        switch (a, b) {
        case let (.click(x), .click(y)): x == y
        case let (.type(r, t, s), .type(r2, t2, s2)): r == r2 && t == t2 && s == s2
        case let (.select(r, o), .select(r2, o2)): r == r2 && o == o2
        case let (.scroll(d), .scroll(d2)): d == d2
        case let (.fillForm(f), .fillForm(g)): f.map { "\($0.ref)=\($0.value)" } == g.map { "\($0.ref)=\($0.value)" }
        default: false
        }
    }

    public enum ParseError: Error, Equatable { case unknownTool(String), badArguments(String) }

    /// « @e3 », « e3 » ou 3.
    static func ref(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        guard let s = any as? String else { return nil }
        return Int(s.drop { $0 == "@" || $0 == "e" || $0 == "E" })
    }

    /// Lit un appel d'outil du modèle (nom + arguments JSON). Les outils sans geste sur la page (`search_web`, `done`…) ne sont pas ici.
    public static func parse(name: String, argumentsJSON: String) throws -> AIAction {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        switch name {
        case "click":
            guard let r = ref(args["ref"]) else { throw ParseError.badArguments("ref") }
            return .click(ref: r)
        case "type":
            guard let r = ref(args["ref"]), let text = args["text"] as? String else { throw ParseError.badArguments("ref/text") }
            return .type(ref: r, text: text, submit: args["submit"] as? Bool ?? false)
        case "select":
            guard let r = ref(args["ref"]), let option = args["option"] as? String else { throw ParseError.badArguments("ref/option") }
            return .select(ref: r, option: option)
        case "scroll":
            let d = (args["direction"] as? String ?? "down").lowercased()
            guard ["up", "down", "top", "bottom"].contains(d) else { throw ParseError.badArguments("direction") }
            return .scroll(direction: d)
        case "fill_form":
            guard let fields = args["fields"] as? [String: Any], !fields.isEmpty else { throw ParseError.badArguments("fields") }
            let list = try fields.compactMap { key, value -> (ref: Int, value: String)? in
                guard let r = ref(key), let v = value as? String else { throw ParseError.badArguments("fields") }
                return (r, v)
            }.sorted { $0.ref < $1.ref }
            return .fillForm(fields: list)
        default: throw ParseError.unknownTool(name)
        }
    }

    /// Les valeurs saisies (avant remplacement des jetons de profil), pour que l'exécuteur les traite.
    public var typedValues: [String] {
        switch self {
        case .type(_, let t, _): [t]
        case .select(_, let o): [o]
        case .fillForm(let f): f.map(\.value)
        default: []
        }
    }
}

/// Ce que le script de la page dit de l'élément visé, avant le geste.
public struct ActionTarget: Equatable, Sendable, Codable {
    public var ref: Int
    public var tag: String
    public var type: String?
    public var label: String
    public var isSubmit = false          // bouton qui enverrait un formulaire
    public var inForm = false
    public var formHasSecret = false     // le formulaire contient un mot de passe ou une carte
    public var href: String?
    public var download = false
    public init(ref: Int, tag: String, type: String? = nil, label: String, isSubmit: Bool = false, inForm: Bool = false, formHasSecret: Bool = false, href: String? = nil, download: Bool = false) {
        self.ref = ref; self.tag = tag; self.type = type; self.label = label; self.isSubmit = isSubmit
        self.inForm = inForm; self.formHasSecret = formHasSecret; self.href = href; self.download = download
    }
    /// Champ secret : jamais rempli par l'IA (le remplissage automatique du navigateur s'en charge).
    public var isSecret: Bool { PageMap.isSecret(type: type, hints: [label]) }
}

public enum ActionDecision: Equatable, Sendable {
    case allow
    case confirm(reason: String)
    case refuse(reason: String)
}

public enum ActionPolicy {
    static let payWords = ["payer", "acheter", "commander", "valider la commande", "finaliser", "confirmer l'achat", "ajouter au panier", "pay", "buy", "purchase", "checkout", "place order"]
    static let downloadExtensions = ["zip", "dmg", "pkg", "exe", "msi", "iso", "pdf", "gz", "tar", "rar", "7z", "apk", "csv", "xlsx", "docx"]
    static let loginWords = ["se connecter", "connexion", "log in", "login", "sign in", "s'identifier"]

    /// Pages où l'IA n'agit pas : l'intérieur d'Orée (réglages, pages internes), les autres schémas que http(s).
    public static func isForbiddenPage(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return true }
        return !["http", "https"].contains(scheme)
    }

    static func isDownloadLink(_ target: ActionTarget) -> Bool {
        if target.download { return true }
        guard let href = target.href, let path = URL(string: href)?.path ?? Optional(href) else { return false }
        return downloadExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Décide pour UN geste sur UN élément. `typing`: la valeur qui serait écrite est un jeton de profil ou du texte (pas de décision ici).
    public static func decide(_ action: AIAction, target: ActionTarget, pageURL: URL?) -> ActionDecision {
        if isForbiddenPage(pageURL) { return .refuse(reason: "L'IA n'agit pas sur cette page.") }
        switch action {
        case .scroll: return .allow
        case .type(_, _, let submit):
            if target.isSecret { return .refuse(reason: "Les mots de passe et les cartes se remplissent avec le remplissage automatique, pas avec l'IA.") }
            return submit ? .confirm(reason: "Envoyer le formulaire") : .allow
        case .select:
            return target.isSecret ? .refuse(reason: "Champ protégé.") : .allow
        case .fillForm:
            return target.isSecret ? .refuse(reason: "Champ protégé.") : .allow
        case .click:
            let label = target.label.lowercased()
            if target.isSubmit { return .confirm(reason: target.formHasSecret ? "Se connecter ou payer : « \(target.label) »" : "Envoyer le formulaire : « \(target.label) »") }
            if payWords.contains(where: label.contains) { return .confirm(reason: "Achat ou paiement : « \(target.label) »") }
            if loginWords.contains(where: label.contains), target.formHasSecret { return .confirm(reason: "Connexion : « \(target.label) »") }
            if isDownloadLink(target) { return .confirm(reason: "Télécharger un fichier : « \(target.label) »") }
            return .allow
        }
    }
}

/// Les jetons `{{profil.xxx}}` : le modèle écrit le jeton, le navigateur met la vraie valeur, qui ne revient jamais au modèle.
public enum ProfileTokens {
    public enum TokenError: Error, Equatable { case unknown(String) }

    static let pattern = try! NSRegularExpression(pattern: #"\{\{\s*profil\.([a-zA-Z0-9_]+)\s*\}\}"#)

    public static func keys(in text: String) -> [String] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
    }

    /// Remplace chaque jeton par sa valeur ; un jeton inconnu est une erreur (on n'écrit jamais « {{profil.x}} » dans un champ).
    /// La valeur insérée n'est pas relue : un profil qui contiendrait « {{profil.autre}} » ne déclenche pas de second remplacement.
    public static func resolve(_ text: String, profile: [String: String]) throws -> String {
        var result = text
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: text), let keyRange = Range(match.range(at: 1), in: text) else { continue }
            let key = String(text[keyRange])
            guard let value = profile[key] else { throw TokenError.unknown(key) }
            result.replaceSubrange(whole, with: value)
        }
        return result
    }
}
