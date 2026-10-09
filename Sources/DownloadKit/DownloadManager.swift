import Foundation

/// Owns every download of the engine: probes, starts, pauses, resumes, cancels, persists, and publishes
/// progress. Lives in the separate `OreeDownloader` process (or in-process as a fallback).
public actor DownloadManager {
    private let store: StateStore
    private let allowedDirectories: [URL]?
    private var jobs: [UUID: DownloadJob] = [:]
    private var lastSample: [UUID: (bytes: Int64, time: Date, speed: Double)] = [:]
    private var subscribers: [UUID: AsyncStream<[DownloadSnapshot]>.Continuation] = [:]
    private var ticker: Task<Void, Never>?
    private var lastPersist = Date.distantPast
    private let tuning: EngineTuning
    /// While the browser loads a page, downloads may use only this share of their speed (then full speed again).
    public var browsingShare = 0.3
    private var browsing = false

    /// - Parameter allowedDirectories: when set, files may only be written under these folders.
    public init(store: StateStore = .standard, allowedDirectories: [URL]? = nil, tuning: EngineTuning = EngineTuning()) {
        self.tuning = tuning
        self.store = store
        self.allowedDirectories = allowedDirectories?.map { $0.standardizedFileURL }
    }

    // MARK: Start / control

    /// Probes the server and, if it supports Range, takes over. Otherwise nothing is created and the
    /// caller keeps its own download.
    public func start(_ spec: DownloadRequestSpec) async -> StartOutcome {
        guard isAllowed(spec.destinationDirectory) else { return .unsupported(reason: DownloadError.destinationNotAllowed.localizedDescription) }
        guard ["http", "https"].contains(spec.url.scheme?.lowercased() ?? "") else { return .unsupported(reason: "schéma non pris en charge") }
        let session = RangeSession(maxConnections: spec.maxConnections)
        let outcome: ProbeOutcome
        do { outcome = try await session.probe(spec) } catch {
            session.invalidate()
            return .unsupported(reason: "réseau : \(error.localizedDescription)")
        }
        guard case .rangeSupported(let probe) = outcome else {
            session.invalidate()
            if case .unsupported(let reason) = outcome { return .unsupported(reason: reason) }
            return .unsupported(reason: "inconnu")
        }
        let mirrors = spec.useMirrors ? await discoverMirrors(for: spec, probe: probe, session: session) : []
        try? FileManager.default.createDirectory(at: spec.destinationDirectory, withIntermediateDirectories: true)
        let part = spec.destinationDirectory.appendingPathComponent(".\(probe.name).\(spec.id.uuidString.prefix(8)).oreedl").path
        let state = PersistedDownload(spec: spec, name: probe.name, partPath: part, total: probe.total, etag: probe.etag,
                                      lastModified: probe.lastModified,
                                      segments: SegmentPlanner.initial(total: probe.total, connections: spec.maxConnections),
                                      phase: .running, mirrors: mirrors)
        let job = DownloadJob(state: state, store: store, session: session, tuning: tuning, onChange: { [weak self] in
            Task { await self?.publish() }
        })
        jobs[spec.id] = job
        if browsing { await job.setShare(browsingShare) }
        await job.start(resetFile: true)
        startTicker()
        return .accepted
    }

    public func pause(_ id: UUID) async { await jobs[id]?.pause() }

    /// Continues a paused or failed download — after checking the file did not change on the server.
    public func resume(_ id: UUID) async {
        guard let job = jobs[id] else { return }
        let phase = await job.phase
        guard phase == .paused || phase == .failed else { return }
        guard let state = store.load(id) else { return }
        // Same validators and size as before? Otherwise restart cleanly (the old bytes would be wrong).
        var reset = !FileManager.default.fileExists(atPath: state.partPath) || !SegmentFile.hasSize(state.total, at: state.partPath)
        var fresh: ProbeResult?
        let probeSession = RangeSession(maxConnections: 1)
        if case .rangeSupported(let probe)? = try? await probeSession.probe(state.spec) {
            fresh = probe
            if probe.total != state.total { reset = true }
            else if let old = state.etag { reset = reset || probe.etag != old }
            else if let old = state.lastModified { reset = reset || probe.lastModified != old }
        }
        probeSession.invalidate()
        await job.restart(reset: reset, adopting: reset ? fresh : nil)
        if browsing { await job.setShare(browsingShare) }
        startTicker()
    }

    public func cancel(_ id: UUID) async {
        if let job = jobs[id] { await job.cancel() } else { store.remove(id) }
        jobs[id] = nil
        lastSample[id] = nil
        publish()
    }

    /// Forgets a finished / failed download (the user cleared it from the list).
    public func remove(_ id: UUID) async {
        if let job = jobs[id], await job.phase.isActive { return }
        jobs[id] = nil
        store.remove(id)
        publish()
    }

    /// The browser started / finished loading a page: slow downloads down meanwhile, then restore full speed.
    public func setBrowsingActive(_ active: Bool) async {
        guard active != browsing else { return }
        browsing = active
        for job in jobs.values where await job.phase.isActive { await job.setShare(active ? browsingShare : 1) }
    }

    // MARK: Mirrors

    /// Mirrors named by `Link: rel=duplicate` or a Metalink file, kept only if they serve the very same file
    /// (same size and a matching validator) and support Range. They never get the origin's cookies.
    private func discoverMirrors(for spec: DownloadRequestSpec, probe: ProbeResult, session: RangeSession) async -> [URL] {
        var candidates = probe.links.filter { $0.rel == "duplicate" }.sorted { $0.priority < $1.priority }.map(\.url)
        if let described = probe.links.first(where: { $0.rel == "describedby" && ($0.type ?? "").contains("metalink") }),
           let data = await session.fetchData(described.url, spec: spec, credentials: described.url.host == spec.url.host),
           let metalink = Metalink.parse(data), metalink.size == nil || metalink.size == probe.total {
            candidates += metalink.urls.map(\.url)
        }
        var seen: Set<URL> = [spec.url, probe.finalURL]
        var accepted: [URL] = []
        for url in candidates where accepted.count < 4 && !seen.contains(url) && ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            seen.insert(url)
            guard case .rangeSupported(let other)? = try? await session.probe(spec, url: url, credentials: url.host == spec.url.host),
                  other.total == probe.total else { continue }
            let sameVersion = (probe.etag != nil && other.etag == probe.etag) || (probe.lastModified != nil && other.lastModified == probe.lastModified)
            if sameVersion { accepted.append(url) }
        }
        return accepted
    }

    // MARK: State

    /// Loads downloads saved by a previous run: unfinished ones come back paused, ready to resume.
    /// - Parameter autoResume: restart the ones that were still running when the process died (reboot, crash).
    public func loadPersisted(autoResume: Bool = false) async {
        var interrupted: [UUID] = []
        for var saved in store.loadAll() where jobs[saved.spec.id] == nil {
            if saved.phase.isActive { saved.phase = .paused; interrupted.append(saved.spec.id) }
            let session = RangeSession(maxConnections: saved.spec.maxConnections)
            jobs[saved.spec.id] = DownloadJob(state: saved, store: store, session: session, tuning: tuning, onChange: { [weak self] in
                Task { await self?.publish() }
            })
        }
        if autoResume { for id in interrupted { await resume(id) } }
    }

    public func list() async -> [DownloadSnapshot] {
        var result: [DownloadSnapshot] = []
        for job in jobs.values { result.append(await job.snapshot(speed: lastSample[job.id]?.speed ?? 0)) }
        return result.sorted { $0.name < $1.name }
    }

    public var hasActiveWork: Bool {
        get async {
            for job in jobs.values where await job.phase.isActive { return true }
            return false
        }
    }

    /// Progress updates (every ~250 ms while something runs, and on every state change).
    public func updates() -> AsyncStream<[DownloadSnapshot]> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.dropSubscriber(id) } }
        }
    }

    private func dropSubscriber(_ id: UUID) { subscribers[id] = nil }

    // MARK: Publishing

    private func isAllowed(_ directory: URL) -> Bool {
        guard let allowedDirectories else { return true }
        let target = directory.standardizedFileURL.path
        return allowedDirectories.contains { target == $0.path || target.hasPrefix($0.path + "/") }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                if await !self.tick() { break }
            }
            await self?.tickerEnded()
        }
    }

    private func tickerEnded() { ticker = nil }

    /// Returns false when nothing is running any more (the ticker stops).
    private func tick() async -> Bool {
        var anyActive = false
        let now = Date()
        for job in jobs.values {
            guard await job.phase == .running else { continue }
            anyActive = true
            let bytes = job.received
            if let previous = lastSample[job.id] {
                let dt = now.timeIntervalSince(previous.time)
                if dt > 0 {
                    let instant = Double(bytes - previous.bytes) / dt
                    lastSample[job.id] = (bytes, now, previous.speed == 0 ? instant : previous.speed * 0.7 + instant * 0.3)
                }
            } else { lastSample[job.id] = (bytes, now, 0) }
        }
        if now.timeIntervalSince(lastPersist) > 1 {
            lastPersist = now
            for job in jobs.values where await job.phase == .running { await job.persist() }
        }
        await publishNow()
        return anyActive
    }

    private nonisolated func publish() { Task { await self.publishNow() } }

    private func publishNow() async {
        guard !subscribers.isEmpty else { return }
        let snapshots = await list()
        for continuation in subscribers.values { continuation.yield(snapshots) }
    }
}
