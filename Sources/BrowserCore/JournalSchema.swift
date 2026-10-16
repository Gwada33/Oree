import Foundation

/// Ce que le journal a le droit d'écrire. Chaque événement a une liste fermée de champs, chacun avec sa forme (nombre borné, texte d'une liste, empreinte, oui/non).
/// Tout passe par `validate` avant d'être écrit : un champ inconnu est jeté, un nombre est ramené dans ses bornes, un texte hors liste est refusé.
/// C'est la garantie de confidentialité du journal : même une page web qui enverrait de faux événements ne pourrait y faire entrer ni adresse, ni titre, ni texte.
public enum JournalSchema {
    public static let version = 1

    public enum Kind: Sendable {
        case int(ClosedRange<Int>)
        case double(ClosedRange<Double>)
        case bool
        case choice(Set<String>)
        case hash            // une empreinte de site (16 caractères hexadécimaux) ou un identifiant d'onglet (4)
        case version         // « 1.1.0 »
    }

    private static func n(_ max: Int, min: Int = 0) -> Kind { .int(min...max) }
    private static let ms = Kind.int(0...3_600_000)
    private static let secs = Kind.int(0...604_800)
    private static let grid = Kind.int(0...9)
    private static func one(_ values: String...) -> Kind { .choice(Set(values)) }

    static let how = one("new", "link", "palette", "restore", "external", "duplicate", "archive", "reopen", "peek", "mini", "detach", "other")
    static let via = one("click", "keyboard", "palette", "recent", "close", "open", "restore", "space", "other")
    static let panels = one("ai", "notes", "downloads", "history", "favorites", "reading", "webpanel", "peek", "mini", "settings", "palette", "archive", "find", "overview", "customize", "site", "taskmanager")

    /// nom de l'événement → champs permis
    public static let events: [String: [String: Kind]] = [
        // Session et système
        "session.start": ["ver": .version, "os": n(99), "scale": n(4, min: 1), "cores": n(64), "mem": n(512), "lowpower": .bool, "charging": .bool, "cold": ms, "restored": n(500)],
        "session.end": ["dur": secs],
        "app.active": ["on": .bool],
        "sys.state": ["thermal": one("nominal", "fair", "serious", "critical"), "lowpower": .bool, "charging": .bool, "mempress": one("normal", "warning", "critical")],
        "window.layout": ["w": n(80), "h": n(60), "sidebar": one("fixed", "compact", "floating", "hidden"), "tabs": one("vertical", "horizontal"), "fs": .bool, "mini": .bool],
        "perf.mem": ["tabs": n(1000), "awake": n(1000), "mb": n(200_000), "top": n(100_000), "sleeping": n(1000)],
        // Onglets
        "tab.open": ["tab": .hash, "how": how, "opener": .hash, "n": n(1000), "space": n(20)],
        "tab.select": ["tab": .hash, "prev": .hash, "via": via, "dwell": ms, "gap": secs, "asleep": .bool],
        "tab.close": ["tab": .hash, "life": secs, "fg": secs, "why": one("user", "archive", "window", "quit", "detach"), "n": n(1000)],
        "tab.sleep": ["tab": .hash, "idle": secs, "mb": n(100_000), "why": one("budget", "user", "idle", "pressure", "other")],
        "tab.wake": ["tab": .hash, "ms": ms, "trigger": one("hover", "select", "other"), "ghost": .bool],
        "tab.move": ["tab": .hash, "steps": .int(-1000...1000)],
        "tab.hover": ["tab": .hash, "dwell": ms, "preview": .bool, "clicked": .bool],
        "space.switch": ["from": n(20), "to": n(20)],
        // Navigation
        "nav.start": ["tab": .hash, "site": .hash, "from": .hash, "kind": one("typed", "link", "back", "forward", "reload", "restore", "form", "external", "script", "other"), "same": .bool],
        "nav.commit": ["tab": .hash, "ms": ms],
        "nav.done": ["tab": .hash, "site": .hash, "ms": ms, "ok": .bool, "code": .int(-9999...999)],
        // Page (envoyé par le script de la page)
        "page.shape": ["tab": .hash, "site": .hash, "links": n(100_000), "buttons": n(100_000), "inputs": n(100_000), "forms": n(1000), "images": n(100_000), "video": .bool, "audio": .bool,
                       "tlen": n(12), "article": .bool, "password": .bool, "h": n(600), "kind": one("article", "app", "search", "video", "form", "home", "other")],
        "page.perf": ["tab": .hash, "site": .hash, "ttfb": ms, "dcl": ms, "load": ms, "lcp": ms],
        "page.leave": ["tab": .hash, "site": .hash, "dwell": secs, "scroll": n(100), "clicks": n(100_000), "keys": n(1_000_000), "moves": n(1_000_000)],
        // Pointeur, défilement, clavier (résumés par fenêtres : jamais une trajectoire, jamais une touche)
        "link.hover": ["tab": .hash, "site": .hash, "same": .bool, "dwell": ms, "clicked": .bool, "gx": grid, "gy": grid, "y": n(400), "kind": one("nav", "content", "button", "other"), "external": .bool],
        "link.click": ["tab": .hash, "site": .hash, "same": .bool, "dwell": ms, "new": .bool, "via": one("mouse", "middle", "modifier", "keyboard"), "gx": grid, "gy": grid, "external": .bool],
        "ptr.window": ["tab": .hash, "dur": ms, "dist": n(1_000_000), "vmean": n(100_000), "vmax": n(200_000), "pauses": n(10_000), "turns": n(10_000), "dx": .int(-100_000...100_000), "dy": .int(-100_000...100_000)],
        "ptr.click": ["tab": .hash, "tag": one("a", "button", "input", "select", "textarea", "video", "img", "other"), "gx": grid, "gy": grid, "since": ms],
        "scroll.window": ["tab": .hash, "dur": ms, "dy": .int(-1_000_000...1_000_000), "vmax": n(500_000), "turns": n(10_000), "depth": n(100)],
        "key.window": ["tab": .hash, "n": n(100_000), "dur": ms, "in": one("field", "page")],
        "field.focus": ["tab": .hash, "kind": one("text", "search", "email", "number", "other")],
        "text.select": ["tab": .hash, "len": n(12), "copy": .bool],
        // Barre d'adresse
        "addr.focus": ["tab": .hash, "how": one("click", "shortcut", "newtab", "other")],
        "addr.input": ["keys": n(10_000), "ms": ms, "len": n(12), "deletes": n(10_000)],
        "addr.suggest": ["n": n(50), "hist": n(50), "bookmark": n(50), "search": n(50), "site": n(50), "pick": .int(-1...50), "kind": one("history", "bookmark", "search", "site", "inline", "typed", "none")],
        "addr.commit": ["tab": .hash, "kind": one("url", "search", "suggestion", "inline", "other"), "ms": ms, "newtab": .bool],
        // Interface
        "ui.panel": ["name": panels, "open": .bool],
        "palette.use": ["action": one("tab", "space", "page", "tool", "setting", "search", "other"), "q": n(12), "ms": ms, "results": n(200)],
        "dl.start": ["site": .hash, "size": n(12)],
        "dl.done": ["ms": ms, "size": n(12), "ok": .bool],
        "media": ["tab": .hash, "site": .hash, "state": one("play", "pause", "end"), "pip": .bool],
        "ai.task": ["route": one("direct", "page", "web", "agent"), "req": n(100), "tin": n(1_000_000), "tout": n(1_000_000), "ms": .int(0...600_000), "ok": .bool, "retries": n(100), "searches": n(100)],
    ]

    /// Garde seulement ce que le schéma permet. nil : événement inconnu ou vide de tout champ permis alors qu'il en exigeait (jamais écrit tel quel).
    public static func validate(_ event: JournalEvent) -> JournalEvent? {
        guard let fields = events[event.e] else { return nil }
        var clean: [String: JournalValue] = [:]
        for (key, value) in event.d {
            guard let kind = fields[key], let checked = check(value, kind) else { continue }
            clean[key] = checked
        }
        return JournalEvent(t: (event.t * 1000).rounded() / 1000, e: event.e, d: clean)
    }

    static func check(_ value: JournalValue, _ kind: Kind) -> JournalValue? {
        switch kind {
        case .int(let range):
            guard let v = value.double, v.isFinite else { return nil }
            return .int(min(max(Int(v.rounded()), range.lowerBound), range.upperBound))
        case .double(let range):
            guard let v = value.double, v.isFinite else { return nil }
            return .double(min(max(v, range.lowerBound), range.upperBound))
        case .bool: return value.bool.map(JournalValue.bool)
        case .choice(let allowed): return value.string.flatMap { allowed.contains($0) ? .string($0) : nil }
        case .hash:
            guard let s = value.string, s.count == 4 || s.count == 16, s.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
            return .string(s)
        case .version:
            guard let s = value.string, s.count <= 16, s.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
            return .string(s)
        }
    }
}
