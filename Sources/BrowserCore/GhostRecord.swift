import Foundation
import AdblockBridge

/// A hibernated page: the DOM as it was, plus where it was scrolled. Shown by a JavaScript-less web view
/// while the real page restores underneath (see docs/oree-hibernation.md).
public struct GhostRecord: Codable, Equatable, Sendable {
    public static let formatVersion = 1

    public var v: Int
    public var url: String
    public var title: String
    public var scrollX: Double
    public var scrollY: Double
    /// Viewport size at capture time (points).
    public var vw: Double
    public var vh: Double
    public var html: String
    public var capturedAt: Double?

    public init(v: Int = GhostRecord.formatVersion, url: String, title: String = "", scrollX: Double = 0, scrollY: Double = 0,
                vw: Double = 0, vh: Double = 0, html: String, capturedAt: Double? = nil) {
        self.v = v; self.url = url; self.title = title; self.scrollX = scrollX; self.scrollY = scrollY
        self.vw = vw; self.vh = vh; self.html = html; self.capturedAt = capturedAt
    }

    /// Parses what the capture script returns. nil for an `{"error": …}` answer or malformed JSON.
    public static func parse(scriptResult json: String) -> GhostRecord? {
        guard let data = json.data(using: .utf8), var record = try? JSONDecoder().decode(GhostRecord.self, from: data) else { return nil }
        record.capturedAt = Date().timeIntervalSince1970
        return record
    }
}

/// When a page may be ghosted at all, and which captured records are worth keeping.
public enum GhostPolicy {
    /// HTML above this (uncompressed) is not worth a ghost: the page is too heavy to reproduce faithfully.
    public static let maxHTMLBytes = 5 * 1024 * 1024

    /// Flag `oree.hibernation.ghost` (UserDefaults) or `HB_GHOST=1` in the environment.
    public static func isEnabled(stored: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["HB_GHOST"] == "1" || stored
    }

    /// Never in a private tab (nothing of a private session may reach the disk); only real web pages.
    public static func canCapture(url: URL?, isPrivate: Bool) -> Bool {
        guard !isPrivate, let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    public static func accepts(_ record: GhostRecord) -> Bool {
        record.v == GhostRecord.formatVersion && !record.html.isEmpty && record.html.utf8.count <= maxHTMLBytes
    }
}

/// JSON → zstd (Rust) and back. Encryption (phase 6) is applied by the caller around these bytes.
public enum GhostCodec {
    public static func encode(_ record: GhostRecord, level: Int32 = 3) throws -> Data {
        try ghostCompress(bytes: JSONEncoder().encode(record), level: level)
    }

    public static func decode(_ data: Data) throws -> GhostRecord {
        try JSONDecoder().decode(GhostRecord.self, from: ghostDecompress(bytes: data))
    }
}

/// The folder of ghost files (Rust side: atomic writes, key validation). Keeps the UI layer free of the Rust bindings.
public final class GhostBlobStore: @unchecked Sendable {
    private let store: GhostStore

    public init(directory: URL) throws { store = try GhostStore(dir: directory.path) }

    public func put(key: String, data: Data) throws { try store.put(key: key, bytes: data) }
    public func get(key: String) throws -> Data? { try store.get(key: key) }
    public func remove(key: String) throws { try store.remove(key: key) }
    public func purge() throws { try store.purge() }
    public var totalBytes: UInt64 { store.totalBytes() }
}
