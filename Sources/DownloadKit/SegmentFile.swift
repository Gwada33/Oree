import Foundation
import Darwin

/// The in-progress file: pre-sized (sparse on APFS — no disk is used until bytes arrive) and written with
/// `pwrite` at each segment's own offset. Nothing but one network chunk is ever held in memory.
public final class SegmentFile: @unchecked Sendable {
    private var descriptor: Int32
    public let path: String
    public let size: Int64

    /// - Parameter reset: discard any existing content (fresh download or the file changed on the server).
    public init(path: String, size: Int64, reset: Bool) throws {
        self.path = path
        self.size = size
        let flags = O_RDWR | O_CREAT | (reset ? O_TRUNC : 0)
        descriptor = open(path, flags, 0o644)
        guard descriptor >= 0 else { throw DownloadError.io(String(cString: strerror(errno))) }
        var stats = stat()
        fstat(descriptor, &stats)
        if Int64(stats.st_size) != size {
            guard ftruncate(descriptor, off_t(size)) == 0 else {
                let message = String(cString: strerror(errno))
                close(descriptor)
                throw DownloadError.io(message)
            }
        }
    }

    deinit { if descriptor >= 0 { close(descriptor) } }

    /// Writes all of `data` at `offset` (handles short writes).
    public func write(_ data: Data, at offset: Int64) throws {
        try data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            var position = off_t(offset)
            while remaining > 0 {
                let n = pwrite(descriptor, pointer, remaining, position)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw DownloadError.io(String(cString: strerror(errno)))
                }
                pointer += n; remaining -= n; position += off_t(n)
            }
        }
    }

    public func sync() { if descriptor >= 0 { fsync(descriptor) } }

    public func closeFile() {
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
    }

    /// Does an existing file at `path` have exactly this size (so its bytes can be trusted for a resume)?
    public static func hasSize(_ size: Int64, at path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) == size
    }
}

/// Marks a finished file as downloaded from the web so Gatekeeper vets it (the same tag Safari applies).
public enum DownloadQuarantine {
    @discardableResult
    public static func apply(to file: URL, source: URL, page: URL?) -> Bool {
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Orée",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineTimeStampKey as String: Date(),
            kLSQuarantineDataURLKey as String: source,
        ]
        if let page { properties[kLSQuarantineOriginURLKey as String] = page }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var target = file
        do { try target.setResourceValues(values); return true } catch { return false }
    }
}

public enum FileNaming {
    /// `name`, or `name (1).ext`, `name (2).ext`… so nothing is ever overwritten.
    public static func uniqueURL(in directory: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var counter = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }
}
