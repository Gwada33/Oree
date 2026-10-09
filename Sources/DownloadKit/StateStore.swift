import Foundation

/// Everything needed to resume (or just display) a download after a crash, a quit or a reboot.
public struct PersistedDownload: Codable, Sendable, Equatable {
    public var spec: DownloadRequestSpec
    public var name: String
    /// The in-progress file (sparse, pre-allocated to the full size).
    public var partPath: String
    public var total: Int64
    public var etag: String?
    public var lastModified: String?
    public var segments: [Segment]
    public var phase: DownloadPhase
    public var finalPath: String?
    public var error: String?
    public var updatedAt: Date
    /// Validated mirror URLs (phase 2). Optional so states written by phase 1 still decode.
    public var mirrors: [URL]?

    public init(spec: DownloadRequestSpec, name: String, partPath: String, total: Int64, etag: String?, lastModified: String?,
                segments: [Segment], phase: DownloadPhase, finalPath: String? = nil, error: String? = nil, updatedAt: Date = Date(), mirrors: [URL]? = nil) {
        self.spec = spec; self.name = name; self.partPath = partPath; self.total = total; self.etag = etag
        self.lastModified = lastModified; self.segments = segments; self.phase = phase; self.finalPath = finalPath
        self.error = error; self.updatedAt = updatedAt; self.mirrors = mirrors
    }

    public var received: Int64 { phase == .finished ? total : SegmentPlanner.received(segments) }
}

/// One small JSON file per download, replaced atomically — a crash can never leave a half-written state.
public final class StateStore: @unchecked Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static var standard: StateStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return StateStore(directory: base.appendingPathComponent("Orée/Downloads", isDirectory: true))
    }

    private func url(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    public func save(_ state: PersistedDownload) {
        var copy = state
        copy.updatedAt = Date()
        guard let data = try? JSONEncoder().encode(copy) else { return }
        try? data.write(to: url(state.spec.id), options: .atomic)
    }

    public func load(_ id: UUID) -> PersistedDownload? {
        guard let data = try? Data(contentsOf: url(id)) else { return nil }
        return try? JSONDecoder().decode(PersistedDownload.self, from: data)
    }

    public func loadAll() -> [PersistedDownload] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(PersistedDownload.self, from: $0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func remove(_ id: UUID) { try? FileManager.default.removeItem(at: url(id)) }
}
