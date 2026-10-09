import AppKit
import WebKit
import BrowserCore
import DownloadKit
import DownloadProtocol

/// The browser's side of downloads: picks the engine (the separate downloader process, or an in-process
/// fallback), hands `WKDownload`s over to it, keeps a WebKit fallback for what the engine cannot take,
/// and exposes one list for the interface.
@MainActor
final class DownloadsController {
    struct Item: Identifiable, Equatable {
        enum Origin { case engine, webkit }
        var id: UUID
        var name: String
        var sourceURL: URL
        var phase: DownloadPhase
        var received: Int64
        var total: Int64?
        var bytesPerSecond: Double
        var connections: Int
        var error: String?
        var fileURL: URL?
        var origin: Origin
        var sources = 1
        var throttled = false

        var fraction: Double? { total.flatMap { $0 > 0 ? min(1, Double(received) / Double($0)) : nil } }
        var snapshot: DownloadSnapshot {
            DownloadSnapshot(id: id, name: name, sourceURL: sourceURL, destination: fileURL ?? URL(fileURLWithPath: "/"), phase: phase,
                             received: received, total: total, bytesPerSecond: bytesPerSecond, connections: connections, error: error, sources: sources, throttled: throttled)
        }
    }

    /// Aggregate view for the toolbar button.
    struct Summary: Equatable {
        var running: Int
        var fraction: Double?
        var bytesPerSecond: Double
    }

    private final class WebKitEntry {
        let download: WKDownload
        let itemID: UUID
        let destination: URL
        let origin: URL?
        var observation: NSKeyValueObservation?
        var resumeData: Data?
        init(download: WKDownload, itemID: UUID, destination: URL, origin: URL?) {
            self.download = download; self.itemID = itemID; self.destination = destination; self.origin = origin
        }
    }

    private(set) var items: [Item] = []
    var onChange: (() -> Void)?
    var onStart: (() -> Void)?
    var onFinish: (() -> Void)?
    /// The web view to resume interrupted WebKit downloads in.
    var resumeWebView: () -> WKWebView? = { nil }

    private var engine: (any DownloadEngine)?
    private(set) var engineKind = "aucun"
    private var updatesTask: Task<Void, Never>?
    private var firstSeen: [UUID: Date] = [:]
    private var webkit: [ObjectIdentifier: WebKitEntry] = [:]
    private var handedOver: Set<ObjectIdentifier> = []
    private let downloadsDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    // MARK: Engine

    /// Connects to the downloader agent (installing it if needed); falls back to an in-process engine.
    func start() {
        Task { [weak self] in
            guard let self else { return }
            let chosen = await Self.connectEngine(downloads: downloadsDirectory)
            engine = chosen.engine
            engineKind = chosen.kind
            for snapshot in await chosen.engine.list() { merge(snapshot, notify: false) }
            fire()
            updatesTask = Task { [weak self] in
                for await snapshots in chosen.engine.updates() { self?.apply(snapshots) }
            }
        }
    }

    private static func connectEngine(downloads: URL) async -> (engine: any DownloadEngine, kind: String) {
        let env = ProcessInfo.processInfo.environment
        if env["HB_NO_AGENT"] == nil, Bundle.main.bundlePath.hasSuffix(".app"),
           let helper = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("OreeDownloader") {
            // launchctl calls take a while: never on the main thread (the window must stay responsive at launch).
            let bundleID = Bundle.main.bundleIdentifier ?? "com.nolhan.hyperbrowser"
            let installed = await Task.detached { Result { try AgentInstaller.ensureInstalled(executable: helper, bundleIdentifier: bundleID) } }.value
            switch installed {
            case .success:
                let xpc = XPCEngine()
                if await xpc.isReachable(timeout: 6) { return (xpc, "processus séparé") }
            case .failure(let error):
                Log.network.error("Agent de téléchargement indisponible : \(error.localizedDescription, privacy: .public)")
            }
        }
        let manager = DownloadManager(store: .standard, allowedDirectories: [downloads])
        await manager.loadPersisted(autoResume: true)
        return (LocalEngine(manager: manager), "dans l’app")
    }

    // MARK: Browsing priority

    private var pageIsLoading = false
    private var releaseTask: Task<Void, Never>?

    /// The active tab started / finished loading: downloads yield to it, then get their speed back. A page is
    /// considered done 1 s after it stops loading (no flapping between redirects), and never holds downloads
    /// back for more than 30 s.
    func pageLoading(_ loading: Bool) {
        guard SettingsStore.shared.downloadYieldToBrowsing else {
            if pageIsLoading { pageIsLoading = false; releaseTask?.cancel(); send(false) }
            return
        }
        releaseTask?.cancel()
        if loading, !pageIsLoading { pageIsLoading = true; send(true) }
        let delay: Duration = loading ? .seconds(30) : .seconds(1)
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pageIsLoading = false
            self.send(false)
        }
    }

    private func send(_ active: Bool) {
        guard let engine else { return }
        Task { await engine.setBrowsingActive(active) }
    }

    // MARK: Taking over a WKDownload

    /// Called from `decideDestinationUsing`. Returns nil when the engine took over (the WKDownload is
    /// cancelled on purpose), or the destination to keep downloading with WebKit.
    func handle(_ download: WKDownload, response: URLResponse, suggestedFilename: String, pageURL: URL?, isPrivate: Bool) async -> URL? {
        let safeName = HTTPParsing.sanitize(suggestedFilename)
        if let engine, !isPrivate, let request = download.originalRequest, let url = request.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""), (request.httpMethod ?? "GET") == "GET", request.httpBody == nil {
            let settings = SettingsStore.shared
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            var headers = request.allHTTPHeaderFields ?? [:]
            for key in headers.keys where ["cookie", "authorization"].contains(key.lowercased()) { headers[key] = nil }
            if !headers.keys.contains(where: { $0.lowercased() == "user-agent" }) {
                headers["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(UserAgent.applicationName)"
            }
            let spec = DownloadRequestSpec(url: url, headers: headers, cookieHeader: CookieHeader.build(for: url, cookies: cookies),
                                           pageURL: pageURL, suggestedName: safeName, destinationDirectory: downloadsDirectory,
                                           maxConnections: settings.downloadMaxConnections, adaptive: settings.downloadAdaptive,
                                           useMirrors: settings.downloadMirrors)
            if await engine.start(spec) == .accepted {
                handedOver.insert(ObjectIdentifier(download))
                adopt(Item(id: spec.id, name: safeName, sourceURL: url, phase: .running, received: 0,
                           total: response.expectedContentLength > 0 ? response.expectedContentLength : nil,
                           bytesPerSecond: 0, connections: 0, error: nil, fileURL: nil, origin: .engine))
                onStart?()
                return nil
            }
        }
        return trackWebKit(download, response: response, name: safeName)
    }

    /// WebKit keeps the download (no Range, private tab, odd request…): same list, same buttons.
    private func trackWebKit(_ download: WKDownload, response: URLResponse, name: String) -> URL {
        var destination = FileNaming.uniqueURL(in: downloadsDirectory, name: name)
        if destination.lastPathComponent.isEmpty { destination = downloadsDirectory.appendingPathComponent("téléchargement") }
        let id = UUID()
        let entry = WebKitEntry(download: download, itemID: id, destination: destination, origin: download.originalRequest?.url)
        entry.observation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let received = progress.completedUnitCount, total = progress.totalUnitCount
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.webkitProgress(id, received: received, total: total) } }
        }
        webkit[ObjectIdentifier(download)] = entry
        adopt(Item(id: id, name: destination.lastPathComponent, sourceURL: entry.origin ?? URL(string: "about:blank")!, phase: .running,
                   received: 0, total: response.expectedContentLength > 0 ? response.expectedContentLength : nil,
                   bytesPerSecond: 0, connections: 1, error: nil, fileURL: nil, origin: .webkit))
        onStart?()
        return destination
    }

    private func webkitProgress(_ id: UUID, received: Int64, total: Int64) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        if let last = webkitSamples[id] {
            let dt = now.timeIntervalSince(last.time)
            if dt > 0.4 {
                let instant = Double(received - last.bytes) / dt
                items[index].bytesPerSecond = last.speed == 0 ? instant : last.speed * 0.6 + instant * 0.4
                webkitSamples[id] = (received, now, items[index].bytesPerSecond)
            }
        } else { webkitSamples[id] = (received, now, 0) }
        items[index].received = received
        if total > 0 { items[index].total = total }
        fire()
    }
    private var webkitSamples: [UUID: (bytes: Int64, time: Date, speed: Double)] = [:]

    func webkitFinished(_ download: WKDownload) {
        guard let entry = webkit.removeValue(forKey: ObjectIdentifier(download)) else { return }
        entry.observation = nil
        Quarantine.apply(to: entry.destination, originURL: entry.origin)
        DistributedNotificationCenter.default().post(name: Notification.Name("com.apple.DownloadFileFinished"), object: entry.destination.path)
        update(entry.itemID) { $0.phase = .finished; $0.fileURL = entry.destination; $0.received = $0.total ?? $0.received; $0.bytesPerSecond = 0; $0.connections = 0 }
        onFinish?()
    }

    func webkitFailed(_ download: WKDownload, error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        if handedOver.remove(key) != nil { return }          // we cancelled it ourselves after handing it to the engine
        guard let entry = webkit[key] else { return }
        entry.observation = nil
        entry.resumeData = resumeData
        let cancelledByUser = (error as NSError).code == NSURLErrorCancelled
        update(entry.itemID) {
            $0.phase = cancelledByUser && resumeData != nil ? .paused : .failed
            $0.error = cancelledByUser ? nil : error.localizedDescription
            $0.bytesPerSecond = 0; $0.connections = 0
        }
    }

    // MARK: List management

    private func adopt(_ item: Item) {
        firstSeen[item.id] = Date()
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        fire()
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        fire()
    }

    private func apply(_ snapshots: [DownloadSnapshot]) {
        var finishedNow = false
        for snapshot in snapshots {
            if merge(snapshot, notify: false) { finishedNow = true }
        }
        // Engine items the engine no longer reports (cancelled / removed elsewhere) disappear.
        let known = Set(snapshots.map(\.id))
        items.removeAll { $0.origin == .engine && !known.contains($0.id) && $0.phase != .running || ($0.origin == .engine && !known.contains($0.id) && Date().timeIntervalSince(firstSeen[$0.id] ?? .distantPast) > 5) }
        fire()
        if finishedNow { onFinish?() }
    }

    /// - Returns: true if this snapshot completed a download we saw running.
    @discardableResult
    private func merge(_ snapshot: DownloadSnapshot, notify: Bool) -> Bool {
        let item = Item(id: snapshot.id, name: snapshot.name, sourceURL: snapshot.sourceURL, phase: snapshot.phase, received: snapshot.received,
                        total: snapshot.total, bytesPerSecond: snapshot.bytesPerSecond, connections: snapshot.connections, error: snapshot.error,
                        fileURL: snapshot.phase == .finished ? snapshot.destination : nil, origin: .engine,
                        sources: snapshot.sources, throttled: snapshot.throttled)
        var finished = false
        if let index = items.firstIndex(where: { $0.id == snapshot.id }) {
            finished = items[index].phase != .finished && item.phase == .finished
            items[index] = item
        } else {
            firstSeen[item.id] = firstSeen[item.id] ?? Date()
            items.append(item)
            items.sort { (firstSeen[$0.id] ?? .distantPast) > (firstSeen[$1.id] ?? .distantPast) }
        }
        if notify { fire() }
        return finished
    }

    /// Progress can change thousands of times a second (WebKit reports every few KB): tell the interface at most ~10×/s.
    private var fireScheduled = false
    private func fire() {
        guard !fireScheduled else { return }
        fireScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                self?.fireScheduled = false
                self?.onChange?()
            }
        }
    }

    var summary: Summary {
        let running = items.filter { $0.phase == .running }
        let known = running.compactMap { item -> (Int64, Int64)? in item.total.map { (item.received, $0) } }
        let total = known.reduce(Int64(0)) { $0 + $1.1 }
        let fraction: Double? = total > 0 ? Double(known.reduce(Int64(0)) { $0 + $1.0 }) / Double(total) : nil
        return Summary(running: running.count, fraction: fraction, bytesPerSecond: running.reduce(0) { $0 + $1.bytesPerSecond })
    }

    // MARK: Actions

    func pause(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.origin == .engine { Task { await engine?.pause(id) } }
        else if let entry = webkit.values.first(where: { $0.itemID == id }) { entry.download.cancel { data in
            DispatchQueue.main.async { MainActor.assumeIsolated { entry.resumeData = data } }
        } }
    }

    func resume(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.origin == .engine {
            update(id) { $0.phase = .running; $0.error = nil }
            Task { await engine?.resume(id) }
        } else if let key = webkit.first(where: { $0.value.itemID == id })?.key, let entry = webkit[key],
                  let data = entry.resumeData, let webView = resumeWebView() {
            webkit[key] = nil
            webView.resumeDownload(fromResumeData: data) { [weak self] resumed in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    resumed.delegate = webView.navigationDelegate as? WKDownloadDelegate
                    let renewed = WebKitEntry(download: resumed, itemID: id, destination: entry.destination, origin: entry.origin)
                    renewed.observation = resumed.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
                        let r = progress.completedUnitCount, t = progress.totalUnitCount
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.webkitProgress(id, received: r, total: t) } }
                    }
                    self.webkit[ObjectIdentifier(resumed)] = renewed
                    self.update(id) { $0.phase = .running; $0.error = nil }
                }
            }
        }
    }

    func cancel(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.origin == .engine { Task { await engine?.cancel(id) } }
        else if let key = webkit.first(where: { $0.value.itemID == id })?.key {
            if let entry = webkit.removeValue(forKey: key) { entry.observation = nil; handedOver.insert(key); entry.download.cancel { _ in } }
        }
        items.removeAll { $0.id == id }
        fire()
    }

    /// Takes a finished / failed entry off the list.
    func remove(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.phase != .running else { return }
        if item.origin == .engine { Task { await engine?.remove(id) } }
        items.removeAll { $0.id == id }
        fire()
    }

    func clearFinished() { for item in items where item.phase == .finished || item.phase == .failed || item.phase == .cancelled { remove(item.id) } }

    func reveal(_ id: UUID) {
        if let url = items.first(where: { $0.id == id })?.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func open(_ id: UUID) {
        if let url = items.first(where: { $0.id == id })?.fileURL { NSWorkspace.shared.open(url) }
    }

    var hasItems: Bool { !items.isEmpty }

    /// Automation only: one line per download, for scripted tests.
    func debugDescription() -> String {
        items.map { "\($0.id.uuidString.prefix(8)) \($0.origin == .engine ? "engine" : "webkit") \($0.phase.rawValue) \($0.received)/\($0.total ?? -1) \(Int($0.bytesPerSecond)) B/s \($0.connections)c/\($0.sources)s\($0.throttled ? " RALENTI" : "") \($0.name) \($0.error ?? "")" }
            .joined(separator: "\n") + "\nmoteur: \(engineKind)"
    }
    func debugFirstID() -> UUID? { items.first?.id }
}
