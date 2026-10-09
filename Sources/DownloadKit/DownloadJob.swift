import Foundation

/// Thread-safe holder of the segment table. Workers (running on the URLSession queue) and the job actor
/// both touch it, so every access goes through one lock. `next` only advances AFTER the bytes are on disk,
/// so a saved state never claims more than what was really written.
final class SegmentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var segments: [Segment]

    init(_ segments: [Segment]) { self.segments = segments }

    func snapshot() -> [Segment] { lock.lock(); defer { lock.unlock() }; return segments }

    func range(_ index: Int) -> (next: Int64, end: Int64)? {
        lock.lock(); defer { lock.unlock() }
        guard segments.indices.contains(index) else { return nil }
        return (segments[index].next, segments[index].end)
    }

    func advance(_ index: Int, by count: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard segments.indices.contains(index) else { return }
        segments[index].next = min(segments[index].end, segments[index].next + count)
    }

    func isComplete(_ index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return segments.indices.contains(index) ? segments[index].isComplete : true
    }

    func nextIdle(excluding running: Set<Int>) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return segments.indices.first { !segments[$0].isComplete && !running.contains($0) }
    }

    /// Re-cuts the biggest remaining segment so a freed connection has work (see `SegmentPlanner.splitLargest`).
    func splitLargest() -> Int? {
        lock.lock(); defer { lock.unlock() }
        return SegmentPlanner.splitLargest(&segments)
    }

    func replace(_ new: [Segment]) { lock.lock(); segments = new; lock.unlock() }

    var received: Int64 { lock.lock(); defer { lock.unlock() }; return SegmentPlanner.received(segments) }
    var allComplete: Bool { lock.lock(); defer { lock.unlock() }; return segments.allSatisfy(\.isComplete) }
}

/// The servers a download can use: the origin first, then validated mirrors. Races them: spreads the first
/// connections over all sources, then favors the ones that deliver the most per connection and drops the
/// laggards. Mirrors never receive the origin's cookies.
final class SourceSet: @unchecked Sendable {
    struct Source {
        var url: URL
        var isOrigin: Bool
        var credentials: Bool          // may carry the origin's cookies (same host only)
        var bytes: Int64 = 0
        var connectionSeconds = 0.0
        var active = 0
        var lastEvent = Date()
        var alive = true
        var demoted = false
        var speedPerConnection: Double { connectionSeconds > 0.5 ? Double(bytes) / connectionSeconds : 0 }
    }

    private let lock = NSLock()
    private var sources: [Source]

    init(origin: URL, mirrors: [URL]) {
        let host = origin.host
        sources = [Source(url: origin, isOrigin: true, credentials: true)]
            + mirrors.map { Source(url: $0, isOrigin: false, credentials: $0.host == host) }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return sources.filter(\.alive).count }
    func source(_ i: Int) -> Source { lock.lock(); defer { lock.unlock() }; return sources[i] }
    var mirrorURLs: [URL] { lock.lock(); defer { lock.unlock() }; return sources.dropFirst().map(\.url) }

    private func integrate(_ i: Int, _ now: Date) {
        sources[i].connectionSeconds += Double(sources[i].active) * now.timeIntervalSince(sources[i].lastEvent)
        sources[i].lastEvent = now
    }

    /// Chooses the source for a new connection and marks it busy.
    func acquire() -> Int {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let candidates = sources.indices.filter { sources[$0].alive && !sources[$0].demoted }
        let pool = candidates.isEmpty ? sources.indices.filter { sources[$0].alive } : candidates
        let choice: Int
        if pool.count <= 1 { choice = pool.first ?? 0 } else {
            // Explore until every source has been measured, then give each a share proportional to its speed.
            let unmeasured = pool.filter { sources[$0].speedPerConnection == 0 }
            if !unmeasured.isEmpty { choice = unmeasured.min { sources[$0].active < sources[$1].active }! }
            else {
                let total = pool.reduce(0.0) { $0 + sources[$1].speedPerConnection }
                let running = Double(pool.reduce(0) { $0 + sources[$1].active } + 1)
                choice = pool.max { a, b in
                    (sources[a].speedPerConnection / total * running - Double(sources[a].active)) <
                    (sources[b].speedPerConnection / total * running - Double(sources[b].active))
                }!
            }
        }
        integrate(choice, now)
        sources[choice].active += 1
        return choice
    }

    func release(_ i: Int) {
        lock.lock(); defer { lock.unlock() }
        integrate(i, Date())
        sources[i].active = max(0, sources[i].active - 1)
        // Drop a source that is clearly the slowest (< 25 % of the best, once measured).
        let measured = sources.indices.filter { sources[$0].alive && sources[$0].speedPerConnection > 0 }
        if measured.count > 1, let best = measured.map({ sources[$0].speedPerConnection }).max() {
            for j in measured where sources[j].speedPerConnection < best * 0.25 && sources[j].connectionSeconds > 3 { sources[j].demoted = true }
        }
    }

    func record(_ i: Int, bytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        integrate(i, Date())
        sources[i].bytes += bytes
    }

    func markDead(_ i: Int) { lock.lock(); sources[i].alive = false; lock.unlock() }
    var hasOtherAliveSource: Bool { lock.lock(); defer { lock.unlock() }; return sources.filter(\.alive).count > 1 }
}

private final class Verdict: @unchecked Sendable {
    private let lock = NSLock()
    private var _error: DownloadError?
    private var _retryAfter: TimeInterval?
    private var _retriable = true
    private var _throttled = false
    func fail(_ error: DownloadError, retryAfter: TimeInterval? = nil, retriable: Bool, throttled: Bool = false) {
        lock.lock(); _error = error; _retryAfter = retryAfter; _retriable = retriable; _throttled = throttled; lock.unlock()
    }
    var snapshot: (error: DownloadError?, retryAfter: TimeInterval?, retriable: Bool, throttled: Bool) {
        lock.lock(); defer { lock.unlock() }; return (_error, _retryAfter, _retriable, _throttled)
    }
}

/// Tuning knobs (tests shorten the windows).
public struct EngineTuning: Sendable {
    public var adaptiveInterval: TimeInterval = 1.0
    public var gain: Double = 0.10
    public var initialConnections = 2
    public init() {}
}

private enum JobEvent: Sendable {
    case finished(Int, Result<Void, Error>)
    case wake
}

/// One download: parallel Range connections (their number adapts) writing into one pre-sized file, possibly
/// from several servers at once.
actor DownloadJob {
    let spec: DownloadRequestSpec
    private var state: PersistedDownload
    private let store: StateStore
    nonisolated let box: SegmentBox
    nonisolated let sources: SourceSet
    private var file: SegmentFile?
    private let session: RangeSession
    private let tuning: EngineTuning
    private var adaptive: AdaptiveConnections
    private var target: Int
    private var running: [Int: Int] = [:]                // segment index → launch order
    private var launchCounter = 0
    private var workers: [Int: Task<Void, Never>] = [:]
    private var shrinking: Set<Int> = []
    private var runTask: Task<Void, Never>?
    private(set) var phase: DownloadPhase
    private var lastError: String?
    private var window = ThroughputWindow()
    private var throttled = false
    private let onChange: @Sendable () -> Void
    private let maxAttempts = 6

    nonisolated var id: UUID { spec.id }
    nonisolated var received: Int64 { box.received }

    init(state: PersistedDownload, store: StateStore, session: RangeSession, tuning: EngineTuning = EngineTuning(),
         onChange: @escaping @Sendable () -> Void) {
        self.spec = state.spec
        self.state = state
        self.store = store
        self.session = session
        self.tuning = tuning
        self.box = SegmentBox(state.segments)
        self.sources = SourceSet(origin: state.spec.url, mirrors: state.mirrors ?? [])
        let maximum = state.spec.maxConnections
        self.adaptive = AdaptiveConnections(minimum: 1, maximum: maximum, initial: state.spec.adaptive ? min(tuning.initialConnections, maximum) : maximum,
                                            gain: tuning.gain)
        self.target = state.spec.adaptive ? min(tuning.initialConnections, maximum) : maximum
        self.phase = state.phase
        self.lastError = state.error
        self.onChange = onChange
    }

    // MARK: Control

    func start(resetFile: Bool) {
        guard runTask == nil, phase != .finished, phase != .cancelled else { return }
        phase = .running
        lastError = nil
        persist()
        onChange()
        runTask = Task { [weak self] in await self?.run(resetFile: resetFile) }
    }

    /// Starts again after a pause or a failure (`reset` = the file changed: begin from byte 0).
    func restart(reset: Bool, adopting probe: ProbeResult? = nil) {
        guard runTask == nil else { return }
        if reset, let probe {      // a new version of the file: forget the old validators and size
            state.total = probe.total
            state.etag = probe.etag
            state.lastModified = probe.lastModified
        }
        if phase == .failed || phase == .paused { phase = .paused }
        start(resetFile: reset)
    }

    func pause() async {
        guard let task = runTask else { return }
        task.cancel()
        await task.value
        if !phase.isTerminal { phase = .paused }
        persist()
        onChange()
    }

    /// Stops and deletes the partial file and the saved state.
    func cancel() async {
        if let task = runTask { task.cancel(); await task.value }
        phase = .cancelled
        file?.closeFile()
        try? FileManager.default.removeItem(atPath: state.partPath)
        store.remove(spec.id)
        session.invalidate()
        onChange()
    }

    /// Browsing priority: share of the speed this download may use while a page loads (1 = full).
    func setShare(_ share: Double) {
        session.setShare(share)
        throttled = share < 1
        if throttled { adaptive.freeze(until: Date().addingTimeInterval(tuning.adaptiveInterval * 2)); window.reset() }
        onChange()
    }

    func persist() {
        state.segments = box.snapshot()
        state.phase = phase
        state.error = lastError
        state.mirrors = sources.mirrorURLs
        store.save(state)
    }

    func snapshot(speed: Double) -> DownloadSnapshot {
        DownloadSnapshot(id: spec.id, name: state.name, sourceURL: spec.url,
                         destination: state.finalPath.map { URL(fileURLWithPath: $0) } ?? spec.destinationDirectory,
                         phase: phase, received: phase == .finished ? state.total : box.received, total: state.total,
                         bytesPerSecond: phase == .running ? speed : 0, connections: phase == .running ? running.count : 0,
                         error: lastError, sources: sources.count, throttled: throttled && phase == .running)
    }

    var name: String { state.name }

    // MARK: Running

    private func run(resetFile: Bool) async {
        do {
            if resetFile { try await resetToStart() }
            file = try SegmentFile(path: state.partPath, size: state.total, reset: false)
            try await transfer()
            try finalize()
            phase = .finished
        } catch is CancellationError {
            // pause()/cancel() set the phase
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            phase = .failed
            lastError = (error as? DownloadError)?.errorDescription ?? error.localizedDescription
        }
        file?.closeFile()
        if phase != .cancelled { persist() }
        runTask = nil
        onChange()
    }

    private func resetToStart() async throws {
        // Fresh start (the file changed on the server, or the partial file went missing): drop everything.
        let fresh = SegmentPlanner.initial(total: state.total, connections: spec.maxConnections)
        state.segments = fresh
        file?.closeFile()
        _ = try SegmentFile(path: state.partPath, size: state.total, reset: true)
        box.replace(fresh)
    }

    private func launch(_ index: Int, events: AsyncStream<JobEvent>.Continuation) {
        launchCounter += 1
        running[index] = launchCounter
        workers[index] = Task { [self] in
            let result: Result<Void, Error>
            do { try await self.runSegment(index); result = .success(()) } catch { result = .failure(error) }
            events.yield(.finished(index, result))
        }
    }

    private func transfer() async throws {
        running = [:]; workers = [:]; shrinking = []                  // a previous run may have been cancelled mid-way
        window.reset()
        let (events, continuation) = AsyncStream.makeStream(of: JobEvent.self)
        let monitor = Task { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(tuning.adaptiveInterval))
                if Task.isCancelled { break }
                await self.adapt()
                continuation.yield(.wake)
            }
        }
        defer { monitor.cancel(); continuation.finish() }

        var iterator = events.makeAsyncIterator()
        var failure: Error?
        loop: while true {
            if Task.isCancelled { break }
            // Grow: start workers while below the target (re-cutting the biggest segment when none is idle).
            while running.count < target, failure == nil {
                if let index = box.nextIdle(excluding: Set(running.keys)) ?? box.splitLargest() { launch(index, events: continuation) } else { break }
            }
            // Shrink: stop the most recently started workers (their segment keeps its progress and goes idle).
            while running.count - shrinking.count > target, let victim = running.filter({ !shrinking.contains($0.key) }).max(by: { $0.value < $1.value })?.key {
                shrinking.insert(victim)
                workers[victim]?.cancel()
            }
            if running.isEmpty { break }
            guard let event = await iterator.next() else { break loop }       // nil = the task was cancelled
            switch event {
            case .wake: break
            case .finished(let index, let result):
                running[index] = nil; workers[index] = nil
                shrinking.remove(index)
                if case .failure(let error) = result, !(error is CancellationError) { failure = failure ?? error }
            }
            if failure != nil, running.isEmpty { break loop }
            if failure != nil { for task in workers.values { task.cancel() } }
        }
        for task in workers.values { task.cancel() }
        for task in workers.values { await task.value }
        running = [:]; workers = [:]; shrinking = []
        if let failure { throw failure }
        try Task.checkCancellation()
        guard box.allComplete else { throw DownloadError.io("téléchargement incomplet") }
    }

    /// One adaptive step: measure the throughput of the last window and let the controller move `target`.
    private func adapt() {
        guard spec.adaptive, phase == .running else { return }
        let measured = window.sample(bytes: box.received)
        guard let speed = measured, !throttled else { return }
        // Only judge a window in which all the planned connections were actually busy.
        guard running.count == target else { return }
        let remaining = state.total - box.received
        target = adaptive.observe(throughput: speed, canGrow: remaining > 8 << 20)
    }

    /// 429/503: fewer connections for a while.
    private func pushedBack() { adaptive.serverPushedBack(); target = adaptive.target }

    private func runSegment(_ index: Int) async throws {
        var attempt = 0
        while !box.isComplete(index) {
            try Task.checkCancellation()
            guard let (next, end) = box.range(index), next < end else { return }
            let verdict = Verdict()
            let writeFailure = WriteFailure()
            let box = self.box
            let sources = self.sources
            guard let file = self.file else { throw DownloadError.io("fichier fermé") }
            let source = sources.acquire()
            defer { sources.release(source) }
            let info = sources.source(source)
            let validator = info.isOrigin ? (state.etag ?? state.lastModified) : nil     // mirrors have their own validators
            let expectedTotal = state.total
            let request = RangeSession.makeRequest(spec, url: info.url, range: next...(end - 1), ifRange: validator, credentials: info.credentials)
            do {
                try await session.fetch(request, onResponse: { response in
                    switch response.statusCode {
                    case 206:
                        let start = response.value(forHTTPHeaderField: "Content-Range")
                            .flatMap { $0.split(separator: " ").last }
                            .flatMap { $0.split(separator: "-").first }
                            .flatMap { Int64($0) }
                        let total = HTTPParsing.totalFromContentRange(response.value(forHTTPHeaderField: "Content-Range"))
                        if let total, total != expectedTotal { verdict.fail(.fileChanged, retriable: false); return false }
                        if let start, start != next { verdict.fail(.network("décalage de plage"), retriable: true); return false }
                        return true
                    case 200:
                        verdict.fail(validator == nil ? .rangeIgnored : .fileChanged, retriable: false); return false
                    case 416:
                        verdict.fail(.fileChanged, retriable: false); return false
                    case 429, 503:
                        verdict.fail(.http(response.statusCode), retryAfter: HTTPParsing.retryAfterSeconds(response.value(forHTTPHeaderField: "Retry-After")),
                                     retriable: true, throttled: true); return false
                    case 408, 500...599:
                        verdict.fail(.http(response.statusCode), retryAfter: HTTPParsing.retryAfterSeconds(response.value(forHTTPHeaderField: "Retry-After")), retriable: true); return false
                    default:
                        verdict.fail(.http(response.statusCode), retriable: false); return false
                    }
                }, onData: { data in
                    guard let (position, limit) = box.range(index) else { return false }
                    let count = min(Int64(data.count), limit - position)
                    guard count > 0 else { return false }
                    do { try file.write(count == Int64(data.count) ? data : data.prefix(Int(count)), at: position) }
                    catch { writeFailure.set(error); return false }
                    box.advance(index, by: count)
                    sources.record(source, bytes: count)
                    return position + count < limit
                })
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if !info.isOrigin, sources.hasOtherAliveSource { sources.markDead(source); continue }   // a broken mirror: use the others
                attempt += 1
                if attempt >= maxAttempts { throw DownloadError.network(error.localizedDescription) }
                try await Task.sleep(for: .seconds(Backoff.delay(attempt: attempt - 1)))
                continue
            }
            if let failure = writeFailure.error { throw failure }
            let outcome = verdict.snapshot
            if let error = outcome.error {
                // A mirror that misbehaves is dropped (the origin and the others carry on); the origin is retried.
                if !info.isOrigin, sources.hasOtherAliveSource { sources.markDead(source); continue }
                if outcome.throttled { pushedBack() }
                attempt += 1
                guard outcome.retriable, attempt < maxAttempts else { throw error }
                try await Task.sleep(for: .seconds(Backoff.delay(attempt: attempt - 1, retryAfter: outcome.retryAfter)))
                continue
            }
            if !box.isComplete(index) {            // connection closed early without an error: just continue the range
                attempt += 1
                guard attempt < maxAttempts else { throw DownloadError.network("connexion interrompue") }
                try await Task.sleep(for: .seconds(Backoff.delay(attempt: attempt - 1)))
            }
        }
    }

    private func finalize() throws {
        guard box.allComplete, box.received == state.total else { throw DownloadError.io("octets manquants") }
        file?.sync()
        file?.closeFile()
        let final = FileNaming.uniqueURL(in: spec.destinationDirectory, name: state.name)
        do { try FileManager.default.moveItem(atPath: state.partPath, toPath: final.path) }
        catch { throw DownloadError.io(error.localizedDescription) }
        DownloadQuarantine.apply(to: final, source: spec.url, page: spec.pageURL)
        state.finalPath = final.path
        session.invalidate()
    }
}

private final class WriteFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    func set(_ error: Error) { lock.lock(); stored = error; lock.unlock() }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return stored }
}

extension SegmentBox {
    func replaceAll(_ new: [Segment]) { replace(new) }
}
