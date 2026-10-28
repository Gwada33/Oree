import Foundation

/// La mémoire de Luciole : les discussions passées (pour les rouvrir) et un journal de ce qu'elle a fait (pour s'en servir la fois suivante : « la dernière fois sur
/// ce site, j'ai rempli tel formulaire »). Tout reste dans un fichier de ce Mac. Jamais de valeur saisie : seulement les libellés des actions (« Saisie dans « Nom » »),
/// les tâches demandées, les réponses données et les faits que la personne a donnés quand Luciole lui a posé une question. Rien n'est gardé en navigation privée.
public struct LucioleMemory: Codable, Equatable, Sendable {
    public struct TraceLine: Codable, Equatable, Sendable {
        public var text: String
        public var detail: String?
        public var failed: Bool
        public init(text: String, detail: String? = nil, failed: Bool = false) { self.text = text; self.detail = detail; self.failed = failed }
    }
    public struct Message: Codable, Equatable, Sendable {
        public var isUser: Bool
        public var text: String
        public var title: String
        public var sources: [String]
        public var trace: [TraceLine]
        public var capped: Bool
        public var stoppedAtStep: Int?
        public init(isUser: Bool, text: String, title: String = "", sources: [String] = [], trace: [TraceLine] = [], capped: Bool = false, stoppedAtStep: Int? = nil) {
            self.isUser = isUser; self.text = text; self.title = title; self.sources = sources; self.trace = trace; self.capped = capped; self.stoppedAtStep = stoppedAtStep
        }
    }
    public struct Discussion: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var title: String
        public var host: String?
        public var updatedAt: Date
        public var messages: [Message]
        public init(id: UUID = UUID(), title: String, host: String?, updatedAt: Date, messages: [Message]) { self.id = id; self.title = title; self.host = host; self.updatedAt = updatedAt; self.messages = messages }
    }
    public struct Entry: Codable, Equatable, Sendable {
        public var date: Date
        public var host: String?
        public var task: String
        public var actions: [String]          // « Saisie dans « Nom ». », « Clic sur « Réserver » (refusé) »…
        public var answer: String
        public var facts: [String]            // « Quel est votre prénom ? → Nolhan »
        public init(date: Date, host: String?, task: String, actions: [String], answer: String, facts: [String] = []) {
            self.date = date; self.host = host; self.task = task; self.actions = actions; self.answer = answer; self.facts = facts
        }
    }

    public var discussions: [Discussion] = []
    public var journal: [Entry] = []

    public static let maxDiscussions = 40
    public static let maxMessages = 120
    public static let maxJournal = 300

    public init() {}

    /// Ajoute ou remplace une discussion (par son identifiant) ; les plus récentes d'abord, les plus anciennes oubliées au-delà de 40.
    public mutating func upsert(_ discussion: Discussion) {
        var d = discussion
        if d.messages.count > Self.maxMessages { d.messages = Array(d.messages.suffix(Self.maxMessages)) }
        discussions.removeAll { $0.id == d.id }
        discussions.insert(d, at: 0)
        discussions.sort { $0.updatedAt > $1.updatedAt }
        if discussions.count > Self.maxDiscussions { discussions = Array(discussions.prefix(Self.maxDiscussions)) }
    }

    public mutating func record(_ entry: Entry) {
        journal.append(entry)
        if journal.count > Self.maxJournal { journal.removeFirst(journal.count - Self.maxJournal) }
    }

    public mutating func clear() { discussions = []; journal = [] }

    /// Une réponse à une question de Luciole peut être un mot de passe ou un numéro de carte : on ne la garde pas (ni ne la renvoie à un fournisseur en nuage au tour suivant).
    public static func isSafeFact(question: String, answer: String) -> Bool {
        if PageMap.isSecret(type: nil, hints: [question]) { return false }
        let digits = answer.filter(\.isNumber).count
        return digits < 12 && answer.count <= 200
    }

    public static func title(for task: String) -> String {
        let flat = task.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > 44 ? String(flat.prefix(43)) + "…" : flat
    }

    static func relative(_ date: Date, now: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date), to: Calendar.current.startOfDay(for: now)).day ?? 0
        switch days { case ..<1: return "aujourd'hui"; case 1: return "hier"; default: return "il y a \(days) j" }
    }

    /// Ce que Luciole se rappelle, en lignes courtes pour sa consigne : d'abord ce qui concerne le site ouvert, puis le reste, du plus récent au plus ancien.
    public func recall(host: String?, limit: Int, now: Date = Date()) -> [String] {
        guard limit > 0 else { return [] }
        let recent = journal.reversed()
        let same = host.map { h in recent.filter { $0.host == h } } ?? []
        let others = recent.filter { entry in !same.contains(where: { $0.date == entry.date && $0.task == entry.task }) }
        return (same + others).prefix(limit).map { entry in
            var line = "• \(Self.relative(entry.date, now: now))" + (entry.host.map { ", \($0)" } ?? "") + " : « \(String(entry.task.prefix(80))) »"
            if !entry.actions.isEmpty { line += " → " + entry.actions.prefix(4).joined(separator: " ; ") }
            if !entry.answer.isEmpty { line += ". Résultat : " + String(entry.answer.prefix(120)) }
            for fact in entry.facts.prefix(2) { line += ". Appris : " + fact }
            return line
        }
    }

    // MARK: Fichier

    /// `~/Library/Application Support/HyperBrowser/Luciole`, ou — pour une instance d'essai (`HB_DB_PATH`) — un dossier à côté de sa base jetable.
    public static var defaultDirectory: URL {
        if let db = ProcessInfo.processInfo.environment["HB_DB_PATH"] { return URL(fileURLWithPath: db).deletingLastPathComponent().appendingPathComponent("Luciole", isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/HyperBrowser/Luciole", isDirectory: true)
    }

    public static func load(from directory: URL = defaultDirectory) -> LucioleMemory {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("memoire.json")) else { return LucioleMemory() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LucioleMemory.self, from: data)) ?? LucioleMemory()
    }

    @discardableResult
    public func save(to directory: URL = defaultDirectory) -> Bool {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Pas de .completeFileProtection : macOS 27.2 refuse ("Operation not permitted") et rien n'était plus écrit. Droits 0600 à la place (FileVault protège le reste).
            let file = directory.appendingPathComponent("memoire.json")
            try data.write(to: file, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch { return false }
    }

    public static func erase(in directory: URL = defaultDirectory) { try? FileManager.default.removeItem(at: directory.appendingPathComponent("memoire.json")) }
}
