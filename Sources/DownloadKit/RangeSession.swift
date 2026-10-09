import Foundation

/// What the first request told us about the file.
public struct ProbeResult: Sendable, Equatable {
    public var total: Int64
    public var etag: String?
    public var lastModified: String?
    public var name: String
    public var mimeType: String?
    public var finalURL: URL
    /// `Link` headers of the response (mirrors, Metalink description).
    public var links: [HTTPLink] = []
}

public enum ProbeOutcome: Sendable, Equatable {
    case rangeSupported(ProbeResult)
    /// Hand the download back to the browser (no Range, unknown size, empty, odd status…).
    case unsupported(String)
}

/// A `URLSession` that streams response bodies chunk by chunk to a closure (no buffering), strips
/// credentials on cross-host redirects, and bridges to async/await. One session per download.
/// HTTP/2 and HTTP/3 are whatever URLSession negotiates — nothing here disables them.
public final class RangeSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Box {
        var onResponse: @Sendable (HTTPURLResponse) -> Bool
        var onData: @Sendable (Data) -> Bool
        var continuation: CheckedContinuation<Void, Error>?
        var stoppedByUs = false
        var originalHost: String?
    }

    private let lock = NSLock()
    private var boxes: [Int: Box] = [:]
    private var tasks: [Int: URLSessionTask] = [:]
    private var session: URLSession!
    // Browsing priority: while throttled, every connection is suspended for part of each 1 s cycle.
    private var share = 1.0
    private var phaseOn = true
    private var cycleTick = 0
    private var cycleTimer: DispatchSourceTimer?
    private let cycleQueue = DispatchQueue(label: "oree.downloads.throttle", qos: .utility)

    public init(maxConnections: Int) {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral          // no shared cookie jar / cache / credentials
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = max(1, maxConnections)
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60 * 60 * 24 * 7
        configuration.waitsForConnectivity = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    public func invalidate() {
        setShare(1)
        session.invalidateAndCancel()
    }

    /// Fraction (0.05…1) of the time the connections may run. 1 = full speed. Used to give the page the user is
    /// loading priority, then restore full speed. TCP flow control does the rest (no data is dropped).
    public func setShare(_ value: Double) {
        lock.lock()
        share = max(0.05, min(1, value))
        if share >= 1 {
            cycleTimer?.cancel(); cycleTimer = nil
            phaseOn = true
            let all = Array(tasks.values)
            lock.unlock()
            all.forEach { $0.resume() }          // resuming a running task is harmless
            return
        }
        if cycleTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: cycleQueue)
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.cycleStep() }
            cycleTimer = timer
            timer.resume()
        }
        lock.unlock()
    }

    public var currentShare: Double { lock.lock(); defer { lock.unlock() }; return share }

    private func cycleStep() {
        lock.lock()
        cycleTick = (cycleTick + 1) % 10
        let on = Double(cycleTick) < share * 10
        let changed = on != phaseOn
        phaseOn = on
        let all = Array(tasks.values)
        lock.unlock()
        guard changed else { return }
        for task in all { on ? task.resume() : task.suspend() }
    }

    /// Streams `request`. `onResponse` decides whether to keep reading; `onData` receives each chunk and
    /// returns false to stop (a deliberate stop is not an error). Cancelling the Swift task cancels the request.
    public func fetch(_ request: URLRequest,
                      onResponse: @escaping @Sendable (HTTPURLResponse) -> Bool,
                      onData: @escaping @Sendable (Data) -> Bool = { _ in true }) async throws {
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                boxes[task.taskIdentifier] = Box(onResponse: onResponse, onData: onData, continuation: continuation,
                                                 originalHost: request.url?.host)
                tasks[task.taskIdentifier] = task
                let startSuspended = !phaseOn
                lock.unlock()
                task.resume()
                if startSuspended { task.suspend() }
            }
        } onCancel: { task.cancel() }
    }

    // MARK: URLSessionDataDelegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); let box = boxes[dataTask.taskIdentifier]; lock.unlock()
        guard let box, let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        if box.onResponse(http) { completionHandler(.allow) } else {
            lock.lock(); boxes[dataTask.taskIdentifier]?.stoppedByUs = true; lock.unlock()
            completionHandler(.cancel)
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); let box = boxes[dataTask.taskIdentifier]; lock.unlock()
        guard let box else { return }
        if !box.onData(data) {
            lock.lock(); boxes[dataTask.taskIdentifier]?.stoppedByUs = true; lock.unlock()
            dataTask.cancel()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let box = boxes.removeValue(forKey: task.taskIdentifier); tasks[task.taskIdentifier] = nil; lock.unlock()
        guard let box else { return }
        if let error, !(box.stoppedByUs && (error as? URLError)?.code == .cancelled) {
            box.continuation?.resume(throwing: error)
        } else {
            box.continuation?.resume()
        }
    }

    /// Cookies and credentials belong to the site the user was on: never forward them to another host.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); let original = boxes[task.taskIdentifier]?.originalHost; lock.unlock()
        var next = request
        if let original, next.url?.host != original {
            next.setValue(nil, forHTTPHeaderField: "Cookie")
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }

    // MARK: Requests

    public static func makeRequest(_ spec: DownloadRequestSpec, url: URL? = nil, range: ClosedRange<Int64>? = nil,
                                   ifRange: String? = nil, credentials: Bool = true) -> URLRequest {
        var request = URLRequest(url: url ?? spec.url)
        request.httpMethod = "GET"
        for (field, value) in spec.headers where !["cookie", "authorization", "range", "if-range", "host", "content-length"].contains(field.lowercased()) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if credentials, let cookie = spec.cookieHeader, !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")        // byte offsets must match the file on disk
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
        if let ifRange { request.setValue(ifRange, forHTTPHeaderField: "If-Range") }
        return request
    }

    /// `GET Range: bytes=0-0`: tells size, ranges support and validators (HEAD is refused by some CDNs).
    /// - Parameters:
    ///   - url: probe this URL instead of the spec's (a mirror).
    ///   - credentials: send the cookies (only ever for the origin host).
    public func probe(_ spec: DownloadRequestSpec, url: URL? = nil, credentials: Bool = true) async throws -> ProbeOutcome {
        let captured = ProbeBox()
        try await fetch(Self.makeRequest(spec, url: url, range: 0...0, credentials: credentials), onResponse: { response in
            captured.set(response)
            return false          // headers are all we need
        })
        guard let response = captured.response else { return .unsupported("pas de réponse") }
        switch response.statusCode {
        case 206:
            guard let total = HTTPParsing.totalFromContentRange(response.value(forHTTPHeaderField: "Content-Range")), total > 0 else {
                return .unsupported("taille inconnue")
            }
            let name = HTTPParsing.fileName(contentDisposition: response.value(forHTTPHeaderField: "Content-Disposition"),
                                            url: response.url ?? spec.url, suggested: spec.suggestedName)
            return .rangeSupported(ProbeResult(total: total, etag: HTTPParsing.strongETag(response.value(forHTTPHeaderField: "ETag")),
                                               lastModified: response.value(forHTTPHeaderField: "Last-Modified"), name: name,
                                               mimeType: response.mimeType, finalURL: response.url ?? spec.url,
                                               links: HTTPParsing.links(response.value(forHTTPHeaderField: "Link"), base: response.url ?? spec.url)))
        case 200: return .unsupported("le serveur ignore les plages d’octets")
        case 416: return .unsupported("fichier vide ou plage refusée")
        default: return .unsupported("réponse \(response.statusCode)")
        }
    }
}

extension RangeSession {
    /// Small text resources (a Metalink file): at most `limit` bytes, nil on any problem.
    public func fetchData(_ url: URL, spec: DownloadRequestSpec, limit: Int = 256 * 1024, credentials: Bool = false) async -> Data? {
        let collected = DataBox()
        do {
            try await fetch(Self.makeRequest(spec, url: url, credentials: credentials), onResponse: { $0.statusCode == 200 },
                            onData: { collected.append($0, limit: limit) })
        } catch { return nil }
        return collected.data
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var overflow = false
    func append(_ chunk: Data, limit: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
        if buffer.count > limit { overflow = true; return false }
        return true
    }
    var data: Data? { lock.lock(); defer { lock.unlock() }; return overflow || buffer.isEmpty ? nil : buffer }
}

private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: HTTPURLResponse?
    func set(_ response: HTTPURLResponse) { lock.lock(); stored = response; lock.unlock() }
    var response: HTTPURLResponse? { lock.lock(); defer { lock.unlock() }; return stored }
}
