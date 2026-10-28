import AppKit
import WebKit
import BrowserCore
import DownloadProtocol

/// chrome.downloads : la liste des téléchargements d'Orée, vue comme dans Chrome (les identifiants y sont des nombres).
@MainActor
final class DownloadWatch {
    var numbers: [UUID: Int] = [:]
    var next = 1
    var known: [Int: String] = [:]          // dernier état connu (pour n'annoncer que les changements)
    var timer: Timer?
}

extension ExtensionBridge {
    private func number(_ id: UUID) -> Int {
        if let n = downloadWatch.numbers[id] { return n }
        let n = downloadWatch.next; downloadWatch.next += 1; downloadWatch.numbers[id] = n; return n
    }

    private func item(_ i: DownloadsController.Item) -> [String: Any] {
        let state = i.phase == .finished ? "complete" : ((i.phase == .failed || i.phase == .cancelled) ? "interrupted" : "in_progress")
        var d: [String: Any] = ["id": number(i.id), "url": i.sourceURL.absoluteString, "finalUrl": i.sourceURL.absoluteString, "referrer": "", "filename": i.fileURL?.path ?? i.name, "incognito": false, "danger": "safe",
                                "mime": "", "startTime": ISO8601DateFormatter().string(from: Date()), "state": state, "paused": i.phase == .paused, "canResume": i.phase == .paused || i.phase == .failed,
                                "bytesReceived": Double(i.received), "totalBytes": Double(i.total ?? -1), "fileSize": Double(i.total ?? i.received), "exists": i.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false]
        if let error = i.error { d["error"] = error }
        return d
    }

    private func fingerprint(_ i: DownloadsController.Item) -> String { "\(i.phase.rawValue)|\(i.received)|\(i.total ?? -1)|\(i.fileURL?.path ?? "")|\(i.error ?? "")" }

    /// Une fois qu'une extension a utilisé chrome.downloads, on surveille la liste (chaque seconde) pour annoncer créations, changements et effacements.
    private func watchDownloads() {
        guard downloadWatch.timer == nil, let window else { return }
        for i in window.downloads.items { downloadWatch.known[number(i.id)] = fingerprint(i) }
        downloadWatch.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            mainActorNow {
                guard let self, let window = self.window else { return }
                var seen = Set<Int>()
                for i in window.downloads.items {
                    let n = self.number(i.id); seen.insert(n); let fp = self.fingerprint(i)
                    if self.downloadWatch.known[n] == nil { self.downloadWatch.known[n] = fp; self.broadcast("downloads.onCreated", self.item(i)) }
                    else if self.downloadWatch.known[n] != fp {
                        let old = self.downloadWatch.known[n] ?? ""; self.downloadWatch.known[n] = fp
                        var change: [String: Any] = ["id": n]
                        let state = i.phase == .finished ? "complete" : ((i.phase == .failed || i.phase == .cancelled) ? "interrupted" : "in_progress")
                        if old.split(separator: "|").first.map(String.init) != i.phase.rawValue { change["state"] = ["current": state] }
                        if i.fileURL?.path != nil { change["filename"] = ["current": i.fileURL!.path] }
                        self.broadcast("downloads.onChanged", change)
                    }
                }
                for n in self.downloadWatch.known.keys where !seen.contains(n) { self.downloadWatch.known[n] = nil; self.broadcast("downloads.onErased", n) }
            }
        }
    }

    func downloadMethods() -> [String: Method] {
        func controller() throws -> DownloadsController { guard let w = window else { throw Failure(message: "fenêtre indisponible") }; return w.downloads }
        func find(_ n: Int) throws -> DownloadsController.Item {
            guard let found = try controller().items.first(where: { number($0.id) == n }) else { throw Failure(message: "Invalid downloadId") }
            return found
        }
        func matches(_ i: DownloadsController.Item, _ q: [String: Any]) -> Bool {
            if let id = q["id"] as? Int, number(i.id) != id { return false }
            if let url = q["url"] as? String, i.sourceURL.absoluteString != url { return false }
            if let part = q["urlRegex"] as? String, i.sourceURL.absoluteString.range(of: part, options: .regularExpression) == nil { return false }
            if let state = q["state"] as? String, (item(i)["state"] as? String) != state { return false }
            if let paused = q["paused"] as? Bool, paused != (i.phase == .paused) { return false }
            if let text = q["query"] as? [String], !text.allSatisfy({ i.name.localizedCaseInsensitiveContains($0) || i.sourceURL.absoluteString.localizedCaseInsensitiveContains($0) }) { return false }
            if let filename = q["filename"] as? String, i.fileURL?.path != filename { return false }
            return true
        }
        return [
            "downloads.download": Method(permission: "downloads") { [self] a, _ in
                watchDownloads()
                guard let urlString = a["url"] as? String, let url = URL(string: urlString), ["http", "https"].contains(url.scheme ?? "") else { throw Failure(message: "Invalid URL") }
                guard let window, let web = window.activeTab?.webView ?? window.tabs.first?.webView else { throw Failure(message: "Aucun onglet pour lancer le téléchargement.") }
                let before = Set(window.downloads.items.map(\.id))
                var request = URLRequest(url: url)
                if let method = a["method"] as? String { request.httpMethod = method }
                for header in (a["headers"] as? [[String: Any]]) ?? [] { if let n = header["name"] as? String, let v = header["value"] as? String { request.setValue(v, forHTTPHeaderField: n) } }
                web.startDownload(using: request) { download in mainActorNow { download.delegate = window } }
                for _ in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if let created = window.downloads.items.first(where: { !before.contains($0.id) && $0.sourceURL == url }) ?? window.downloads.items.first(where: { !before.contains($0.id) }) { return number(created.id) }
                }
                throw Failure(message: "Le téléchargement n'a pas démarré.")
            },
            "downloads.search": Method(permission: "downloads") { [self] a, _ in
                watchDownloads()
                var list = try controller().items.filter { matches($0, a) }
                if let limit = a["limit"] as? Int { list = Array(list.prefix(limit)) }
                return list.map(item)
            },
            "downloads.pause": Method(permission: "downloads") { [self] a, _ in try controller().pause(try find((a["id"] as? Int) ?? -1).id); return NSNull() },
            "downloads.resume": Method(permission: "downloads") { [self] a, _ in try controller().resume(try find((a["id"] as? Int) ?? -1).id); return NSNull() },
            "downloads.cancel": Method(permission: "downloads") { [self] a, _ in try controller().cancel(try find((a["id"] as? Int) ?? -1).id); return NSNull() },
            "downloads.erase": Method(permission: "downloads") { [self] a, _ in
                let c = try controller(); let list = c.items.filter { matches($0, a) }
                for i in list where i.phase != .running { c.remove(i.id) }
                return list.map { number($0.id) }
            },
            "downloads.removeFile": Method(permission: "downloads") { [self] a, _ in
                let i = try find((a["id"] as? Int) ?? -1)
                guard let url = i.fileURL else { throw Failure(message: "Download file doesn't exist.") }
                try FileManager.default.trashItem(at: url, resultingItemURL: nil); return NSNull()
            },
            "downloads.open": Method(permission: "downloads") { [self] a, _ in try controller().open(try find((a["id"] as? Int) ?? -1).id); return NSNull() },
            "downloads.show": Method(permission: "downloads") { [self] a, _ in try controller().reveal(try find((a["id"] as? Int) ?? -1).id); return NSNull() },
            "downloads.showDefaultFolder": Method(permission: "downloads") { _, _ in
                if let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first { NSWorkspace.shared.open(folder) }; return NSNull()
            },
        ]
    }
}
