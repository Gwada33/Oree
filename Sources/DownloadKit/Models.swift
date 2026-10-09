import Foundation

/// Everything the engine needs to start one download. Plain data, so it crosses XPC as JSON.
public struct DownloadRequestSpec: Codable, Sendable, Equatable {
    public var id: UUID
    public var url: URL
    /// Headers of the original request, WITHOUT `Cookie` / `Authorization` (those are passed explicitly).
    public var headers: [String: String]
    /// Ready-made `Cookie` header, already filtered to the cookies that apply to `url`'s host.
    public var cookieHeader: String?
    /// Page the link was on (kept for quarantine / Spotlight "where from").
    public var pageURL: URL?
    public var suggestedName: String?
    /// Where the finished file goes. The service only accepts folders it was told are allowed.
    public var destinationDirectory: URL
    /// Upper bound of parallel connections (1…16). With `adaptive` the engine starts lower and climbs to it.
    public var maxConnections: Int
    /// Grow / shrink the number of connections from the measured throughput (otherwise always `maxConnections`).
    public var adaptive: Bool
    /// Race the origin against mirrors found in `Link: rel=duplicate` headers and Metalink files.
    public var useMirrors: Bool

    public init(id: UUID = UUID(), url: URL, headers: [String: String] = [:], cookieHeader: String? = nil, pageURL: URL? = nil,
                suggestedName: String? = nil, destinationDirectory: URL, maxConnections: Int = 4, adaptive: Bool = false, useMirrors: Bool = false) {
        self.id = id; self.url = url; self.headers = headers; self.cookieHeader = cookieHeader; self.pageURL = pageURL
        self.suggestedName = suggestedName; self.destinationDirectory = destinationDirectory
        self.maxConnections = max(1, min(maxConnections, 16))
        self.adaptive = adaptive; self.useMirrors = useMirrors
    }

    // States saved by phase 1 have no `adaptive` / `useMirrors`: decode them with the phase-1 behavior.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        headers = try c.decode([String: String].self, forKey: .headers)
        cookieHeader = try c.decodeIfPresent(String.self, forKey: .cookieHeader)
        pageURL = try c.decodeIfPresent(URL.self, forKey: .pageURL)
        suggestedName = try c.decodeIfPresent(String.self, forKey: .suggestedName)
        destinationDirectory = try c.decode(URL.self, forKey: .destinationDirectory)
        maxConnections = try c.decode(Int.self, forKey: .maxConnections)
        adaptive = try c.decodeIfPresent(Bool.self, forKey: .adaptive) ?? false
        useMirrors = try c.decodeIfPresent(Bool.self, forKey: .useMirrors) ?? false
    }
}

public enum DownloadPhase: String, Codable, Sendable {
    case probing, running, paused, finished, failed, cancelled
    public var isActive: Bool { self == .probing || self == .running }
    public var isTerminal: Bool { self == .finished || self == .failed || self == .cancelled }
}

/// A moment-in-time view of one download, pushed to the interface a few times per second.
public struct DownloadSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var sourceURL: URL
    /// Final file once finished; the in-progress file's folder before that.
    public var destination: URL
    public var phase: DownloadPhase
    public var received: Int64
    public var total: Int64?
    public var bytesPerSecond: Double
    public var connections: Int
    public var error: String?
    /// Number of servers in use (the origin plus mirrors).
    public var sources: Int
    /// Slowed down on purpose while the browser loads a page.
    public var throttled: Bool

    public init(id: UUID, name: String, sourceURL: URL, destination: URL, phase: DownloadPhase, received: Int64, total: Int64?,
                bytesPerSecond: Double, connections: Int, error: String?, sources: Int = 1, throttled: Bool = false) {
        self.id = id; self.name = name; self.sourceURL = sourceURL; self.destination = destination; self.phase = phase
        self.received = received; self.total = total; self.bytesPerSecond = bytesPerSecond; self.connections = connections; self.error = error
        self.sources = sources; self.throttled = throttled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        sourceURL = try c.decode(URL.self, forKey: .sourceURL); destination = try c.decode(URL.self, forKey: .destination)
        phase = try c.decode(DownloadPhase.self, forKey: .phase); received = try c.decode(Int64.self, forKey: .received)
        total = try c.decodeIfPresent(Int64.self, forKey: .total); bytesPerSecond = try c.decode(Double.self, forKey: .bytesPerSecond)
        connections = try c.decode(Int.self, forKey: .connections); error = try c.decodeIfPresent(String.self, forKey: .error)
        sources = try c.decodeIfPresent(Int.self, forKey: .sources) ?? 1
        throttled = try c.decodeIfPresent(Bool.self, forKey: .throttled) ?? false
    }

    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }

    /// Seconds left at the current speed, if it can be estimated.
    public var secondsRemaining: Double? {
        guard let total, bytesPerSecond > 1, phase == .running else { return nil }
        return Double(max(0, total - received)) / bytesPerSecond
    }
}

/// Result of asking the engine to take over a download.
public enum StartOutcome: Codable, Sendable, Equatable {
    case accepted
    /// The engine cannot (or should not) handle this one; the browser keeps its own download.
    case unsupported(reason: String)
}

public enum DownloadError: Error, Equatable, Sendable, LocalizedError {
    case http(Int)
    case rangeIgnored
    case fileChanged
    case destinationNotAllowed
    case io(String)
    case network(String)
    case unknownDownload

    public var errorDescription: String? {
        switch self {
        case .http(let code): "Le serveur a répondu « \(code) »."
        case .rangeIgnored: "Le serveur a cessé de gérer les téléchargements par morceaux."
        case .fileChanged: "Le fichier a changé sur le serveur."
        case .destinationNotAllowed: "Ce dossier de destination n’est pas autorisé."
        case .io(let message): "Écriture impossible : \(message)"
        case .network(let message): "Réseau : \(message)"
        case .unknownDownload: "Téléchargement introuvable."
        }
    }
}
