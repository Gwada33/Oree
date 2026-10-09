import Foundation
import Network

/// A tiny HTTP/1.1 server for the integration tests: serves deterministic bytes with Range / If-Range /
/// ETag support, and can misbehave on purpose (slow, 429, no Range, redirects).
final class TestServer: @unchecked Sendable {
    struct Config {
        var size: Int64
        var seed: UInt8 = 1
        var etag: String? = "\"v1\""
        var supportsRange = true
        var delayMsPerChunk = 0
        /// Requests starting below this offset are slow (to make one segment lag behind the others).
        var slowBelow: Int64 = 0
        var fail429First = 0
        var contentDisposition: String?
        var redirectTo: String?
        var linkHeader: String?
        var lastModified: String?
        var customBody: Data?
        /// Cheap constant bytes (for speed tests where content does not matter).
        var constantBytes = false
    }

    struct Logged { var path: String; var rangeStart: Int64?; var rangeEnd: Int64?; var cookie: String?; var host: String?; var status: Int }

    private let queue = DispatchQueue(label: "testserver")
    private let lock = NSLock()
    private var listener: NWListener!
    private var configs: [String: Config] = [:]
    private var log: [Logged] = []
    private var active = 0
    private(set) var maxActive = 0
    private var remaining429: [String: Int] = [:]
    private(set) var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [self] state in
            if case .ready = state { port = listener.port?.rawValue ?? 0; ready.signal() }
        }
        listener.newConnectionHandler = { [self] connection in handle(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    deinit { listener.cancel() }

    func serve(_ path: String, _ config: Config) {
        lock.lock(); configs[path] = config; remaining429[path] = config.fail429First; lock.unlock()
    }
    func update(_ path: String, _ change: (inout Config) -> Void) {
        lock.lock(); if var c = configs[path] { change(&c); configs[path] = c }; lock.unlock()
    }
    var requests: [Logged] { lock.lock(); defer { lock.unlock() }; return log }
    func url(_ path: String, host: String = "localhost") -> URL { URL(string: "http://\(host):\(port)\(path)")! }

    static func byte(at offset: Int64, seed: UInt8) -> UInt8 {
        UInt8(truncatingIfNeeded: ((offset &* 2654435761) >> 8) &+ Int64(seed))
    }
    static func bytes(from offset: Int64, count: Int, seed: UInt8) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<count { p[i] = byte(at: offset + Int64(i), seed: seed) }
        }
        return data
    }

    // MARK: Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [self] data, _, done, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                respond(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if error == nil, !done { read(connection, buffer: buffer) } else { connection.cancel() }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2 else { connection.cancel(); return }
        let path = String(parts[1]).components(separatedBy: "?")[0]
        var headers: [String: String] = [:]
        for line in lines.dropFirst() { if let c = line.firstIndex(of: ":") { headers[line[..<c].lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces) } }

        lock.lock(); let config = configs[path]; lock.unlock()
        guard let config else { send(connection, status: "404 Not Found", headers: [:], body: Data()); record(path, nil, headers, 404); return }

        if let body = config.customBody {
            record(path, nil, headers, 200)
            send(connection, status: "200 OK", headers: ["Content-Type": "application/metalink4+xml"], body: body)
            return
        }

        if let target = config.redirectTo {
            record(path, nil, headers, 302)
            send(connection, status: "302 Found", headers: ["Location": target], body: Data())
            return
        }

        var rangeStart: Int64?
        var rangeEnd: Int64?
        if config.supportsRange, let range = headers["range"], range.hasPrefix("bytes=") {
            let spec = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            rangeStart = Int64(spec.first ?? "")
            rangeEnd = spec.count > 1 ? Int64(spec[1]) : nil
        }
        // If-Range with a different validator → the file changed: send everything with 200.
        if let ifRange = headers["if-range"], let etag = config.etag, ifRange != etag { rangeStart = nil; rangeEnd = nil }

        // Throttle on purpose (not for the 1-byte probe).
        if rangeStart != nil, rangeEnd != 0 {
            lock.lock()
            let left = remaining429[path] ?? 0
            if left > 0 { remaining429[path] = left - 1 }
            lock.unlock()
            if left > 0 {
                record(path, rangeStart, headers, 429)
                send(connection, status: "429 Too Many Requests", headers: ["Retry-After": "1"], body: Data())
                return
            }
        }

        let start = rangeStart ?? 0
        let end = min(rangeEnd ?? (config.size - 1), config.size - 1)
        guard start <= end else { send(connection, status: "416 Range Not Satisfiable", headers: ["Content-Range": "bytes */\(config.size)"], body: Data()); record(path, rangeStart, headers, 416); return }
        let isRange = rangeStart != nil
        var out: [String: String] = ["Content-Length": "\(end - start + 1)", "Content-Type": "application/octet-stream", "Accept-Ranges": config.supportsRange ? "bytes" : "none"]
        if let etag = config.etag { out["ETag"] = etag }
        if let cd = config.contentDisposition { out["Content-Disposition"] = cd }
        if let link = config.linkHeader { out["Link"] = link }
        if let modified = config.lastModified { out["Last-Modified"] = modified }
        if isRange { out["Content-Range"] = "bytes \(start)-\(end)/\(config.size)" }
        record(path, isRange ? start : nil, headers, isRange ? 206 : 200)

        lock.lock(); active += 1; maxActive = max(maxActive, active); lock.unlock()
        let head = "HTTP/1.1 \(isRange ? "206 Partial Content" : "200 OK")\r\n" + out.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [self] _ in
            let slow = config.delayMsPerChunk > 0 && start < config.slowBelow || (config.slowBelow == 0 && config.delayMsPerChunk > 0)
            stream(connection, config: config, from: start, to: end, delayMs: slow ? config.delayMsPerChunk : 0)
        })
    }

    private func stream(_ connection: NWConnection, config: Config, from offset: Int64, to end: Int64, delayMs: Int) {
        guard offset <= end else { finish(connection); return }
        let count = Int(min(64 * 1024, end - offset + 1))
        let chunk = config.constantBytes ? Data(count: count) : Self.bytes(from: offset, count: count, seed: config.seed)
        connection.send(content: chunk, completion: .contentProcessed { [self] error in
            if error != nil { finish(connection); return }
            if delayMs > 0 { queue.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { self.stream(connection, config: config, from: offset + Int64(count), to: end, delayMs: delayMs) } }
            else { stream(connection, config: config, from: offset + Int64(count), to: end, delayMs: 0) }
        })
    }

    private func finish(_ connection: NWConnection) {
        lock.lock(); active = max(0, active - 1); lock.unlock()
        connection.cancel()
    }

    private func send(_ connection: NWConnection, status: String, headers: [String: String], body: Data) {
        var all = headers; all["Content-Length"] = "\(body.count)"; all["Connection"] = "close"
        let head = "HTTP/1.1 \(status)\r\n" + all.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func record(_ path: String, _ rangeStart: Int64?, _ headers: [String: String], _ status: Int) {
        let rangeEnd = headers["range"].flatMap { $0.split(separator: "-").last }.flatMap { Int64($0) }
        lock.lock(); log.append(Logged(path: path, rangeStart: rangeStart, rangeEnd: rangeEnd, cookie: headers["cookie"], host: headers["host"], status: status)); lock.unlock()
    }
}
