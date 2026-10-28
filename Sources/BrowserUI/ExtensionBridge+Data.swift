import AppKit
import WebKit
import BrowserCore
import BrowserStorage

/// history, bookmarks, topSites, sessions, readingList : les données d'Orée, vues comme dans Chrome.
extension ExtensionBridge {
    private static func ms(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }
    private static func date(_ value: Any?) -> Date? { (value as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? (value as? Int).map { Date(timeIntervalSince1970: Double($0) / 1000) } }
    private static func string(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = args[key] as? String, !value.isEmpty else { throw Failure(message: "paramètre « \(key) » manquant") }
        return value
    }
    private static func historyItem(_ e: HistoryEntry) -> [String: Any] {
        ["id": String(e.id ?? 0), "url": e.url, "title": e.title, "lastVisitTime": ms(e.lastVisitedAt), "visitCount": e.visitCount, "typedCount": 0]
    }
    private static func bookmarkNode(_ b: Bookmark) -> [String: Any] {
        ["id": String(b.id ?? 0), "parentId": "1", "index": 0, "url": b.url, "title": b.title, "dateAdded": ms(b.createdAt)]
    }
    /// Orée a une liste plate de favoris : on la présente comme la barre de favoris (« 1 ») d'une racine (« 0 ») qui a aussi « Autres favoris » (« 2 », vide).
    private func bookmarkTree() throws -> [String: Any] {
        guard let window else { throw Failure(message: "fenêtre indisponible") }
        let items = try window.bookmarkRepo.all().enumerated().map { index, b -> [String: Any] in var n = Self.bookmarkNode(b); n["index"] = index; return n }
        let bar: [String: Any] = ["id": "1", "parentId": "0", "index": 0, "title": "Favoris", "dateAdded": 0, "children": items]
        let other: [String: Any] = ["id": "2", "parentId": "0", "index": 1, "title": "Autres favoris", "dateAdded": 0, "children": [Any]()]
        return ["id": "0", "title": "", "dateAdded": 0, "children": [bar, other]]
    }

    func dataMethods() -> [String: Method] {
        func history() throws -> HistoryRepository { guard let w = window else { throw Failure(message: "fenêtre indisponible") }; return w.historyRepo }
        func bookmarks() throws -> BookmarkRepository { guard let w = window else { throw Failure(message: "fenêtre indisponible") }; return w.bookmarkRepo }
        func reading() throws -> ReadingListRepository { guard let w = window else { throw Failure(message: "fenêtre indisponible") }; return w.readingRepo }
        return [
            // MARK: history
            "history.search": Method(permission: "history") { a, _ in
                let limit = min(max((a["maxResults"] as? Int) ?? 100, 1), 10_000)
                let since = Self.date(a["startTime"]) ?? Date(timeIntervalSinceNow: -7 * 86_400)     // Chrome : la dernière semaine par défaut
                return try history().entries(matching: (a["text"] as? String) ?? "", since: since, until: Self.date(a["endTime"]), limit: limit).map(Self.historyItem)
            },
            "history.getVisits": Method(permission: "history") { a, _ in
                let url = try Self.string(a, "url")
                return try history().entries(matching: url, since: nil, until: nil, limit: 50).filter { $0.url == url }.map {
                    ["id": String($0.id ?? 0), "visitId": String($0.id ?? 0), "visitTime": Self.ms($0.lastVisitedAt), "referringVisitId": "0", "transition": "link"] as [String: Any]
                }
            },
            "history.addUrl": Method(permission: "history") { a, _ in
                let url = try Self.string(a, "url")
                guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else { throw Failure(message: "adresse invalide") }
                try history().recordVisit(url: url, title: (a["title"] as? String) ?? url); return NSNull()
            },
            "history.deleteUrl": Method(permission: "history") { a, _ in
                let url = try Self.string(a, "url"); try history().remove(url: url); self.broadcast("history.onVisitRemoved", ["allHistory": false, "urls": [url]]); return NSNull()
            },
            "history.deleteRange": Method(permission: "history") { a, _ in
                guard let start = Self.date(a["startTime"]), let end = Self.date(a["endTime"]) else { throw Failure(message: "startTime et endTime sont requis") }
                try history().remove(from: start, to: end); self.broadcast("history.onVisitRemoved", ["allHistory": false, "urls": [String]()]); return NSNull()
            },
            "history.deleteAll": Method(permission: "history") { _, _ in
                try history().clear(); self.broadcast("history.onVisitRemoved", ["allHistory": true]); return NSNull()
            },
            // MARK: topSites
            "topSites.get": Method(permission: "topSites") { _, _ in
                try history().top(limit: 20).map { ["url": $0.url, "title": $0.title] as [String: Any] }
            },
            // MARK: bookmarks
            "bookmarks.getTree": Method(permission: "bookmarks") { _, _ in [try self.bookmarkTree()] },
            "bookmarks.getChildren": Method(permission: "bookmarks") { a, _ in
                switch try Self.string(a, "id") {
                case "0": return ((try self.bookmarkTree())["children"] as? [Any]) ?? []
                case "1": return try bookmarks().all().enumerated().map { i, b -> [String: Any] in var n = Self.bookmarkNode(b); n["index"] = i; return n }
                default: return [Any]()
                }
            },
            "bookmarks.get": Method(permission: "bookmarks") { a, _ in
                let ids: [String]
                if let list = a["ids"] as? [String] { ids = list } else { ids = [try Self.string(a, "id")] }
                let all = try bookmarks().all()
                return try ids.map { id -> [String: Any] in
                    if id == "0" || id == "1" || id == "2" { return ["id": id, "title": id == "2" ? "Autres favoris" : (id == "1" ? "Favoris" : ""), "dateAdded": 0] }
                    guard let b = all.first(where: { String($0.id ?? 0) == id }) else { throw Failure(message: "Can't find bookmark for id.") }
                    return Self.bookmarkNode(b)
                }
            },
            "bookmarks.getRecent": Method(permission: "bookmarks") { a, _ in
                Array(try bookmarks().all().sorted { $0.createdAt > $1.createdAt }.prefix((a["numberOfItems"] as? Int) ?? 10)).map(Self.bookmarkNode)
            },
            "bookmarks.search": Method(permission: "bookmarks") { a, _ in
                let query = ((a["query"] as? String) ?? ((a["query"] as? [String: Any])?["query"] as? String) ?? "").lowercased()
                let object = a["query"] as? [String: Any]
                let wantedURL = object?["url"] as? String, wantedTitle = object?["title"] as? String
                return try bookmarks().all().filter { b in
                    let textOK = query.isEmpty || b.title.lowercased().contains(query) || b.url.lowercased().contains(query)
                    return textOK && (wantedURL == nil || wantedURL == b.url) && (wantedTitle == nil || wantedTitle == b.title)
                }.map(Self.bookmarkNode)
            },
            "bookmarks.create": Method(permission: "bookmarks") { a, _ in
                guard let url = a["url"] as? String, !url.isEmpty else { throw Failure(message: "Orée n'a pas de dossiers de favoris : un favori doit avoir une adresse (url).") }
                let title = (a["title"] as? String) ?? url
                try bookmarks().add(url: url, title: title)
                guard let made = try bookmarks().all().first(where: { $0.url == url }) else { throw Failure(message: "favori non créé") }
                let node = Self.bookmarkNode(made); self.broadcast("bookmarks.onCreated", [String(made.id ?? 0), node]); return node
            },
            "bookmarks.update": Method(permission: "bookmarks") { a, _ in
                let id = try Self.string(a, "id"); let changes = (a["changes"] as? [String: Any]) ?? [:]
                guard let old = try bookmarks().all().first(where: { String($0.id ?? 0) == id }) else { throw Failure(message: "Can't find bookmark for id.") }
                let url = (changes["url"] as? String) ?? old.url, title = (changes["title"] as? String) ?? old.title
                try bookmarks().remove(url: old.url); try bookmarks().add(url: url, title: title, spaceIndex: old.spaceIndex)
                guard let now = try bookmarks().all().first(where: { $0.url == url }) else { throw Failure(message: "favori non mis à jour") }
                self.broadcast("bookmarks.onChanged", [String(now.id ?? 0), ["title": title, "url": url]]); return Self.bookmarkNode(now)
            },
            "bookmarks.remove": Method(permission: "bookmarks") { a, _ in
                let id = try Self.string(a, "id")
                guard let b = try bookmarks().all().first(where: { String($0.id ?? 0) == id }) else { throw Failure(message: "Can't find bookmark for id.") }
                try bookmarks().remove(url: b.url); self.broadcast("bookmarks.onRemoved", [id, ["parentId": "1", "index": 0, "node": Self.bookmarkNode(b)]]); return NSNull()
            },
            // MARK: readingList
            "readingList.query": Method(permission: "readingList") { a, _ in
                try reading().all().filter { ($0.url == (a["url"] as? String)) || a["url"] == nil }.filter { ($0.title == (a["title"] as? String)) || a["title"] == nil }.map {
                    ["url": $0.url, "title": $0.title, "hasBeenRead": false, "creationTime": Self.ms($0.addedAt), "lastUpdateTime": Self.ms($0.addedAt)] as [String: Any]
                }
            },
            "readingList.addEntry": Method(permission: "readingList") { a, _ in
                try reading().add(url: try Self.string(a, "url"), title: (a["title"] as? String) ?? (a["url"] as? String) ?? ""); return NSNull()
            },
            "readingList.removeEntry": Method(permission: "readingList") { a, _ in try reading().remove(url: try Self.string(a, "url")); return NSNull() },
            // MARK: sessions : Orée ne garde pas les onglets fermés ni d'autres appareils
            "sessions.getRecentlyClosed": Method(permission: "sessions") { _, _ in [Any]() },
            "sessions.getDevices": Method(permission: "sessions") { _, _ in [Any]() },
        ]
    }
}
