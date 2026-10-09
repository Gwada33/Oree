import Foundation

public struct FilterListSource: Sendable, Hashable {
    public let name: String
    public let url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }

    public static let easyList = FilterListSource(name: "easylist", url: URL(string: "https://easylist.to/easylist/easylist.txt")!)
    public static let easyPrivacy = FilterListSource(name: "easyprivacy", url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!)
    public static let defaults: [FilterListSource] = [.easyList, .easyPrivacy]
}

/// Downloads and caches filter lists on disk. Updates are conditional
/// (`ETag` / `Last-Modified`) so a "check" for an unchanged list costs a
/// tiny 304 response, and a failed or bogus download never replaces a good
/// cached copy.
public actor FilterListStore {
    private struct Metadata: Codable {
        var etag: String?
        var lastModified: String?
        var lastChecked: Date?
    }

    private let directory: URL
    private let session: URLSession

    public init(directory: URL? = nil, session: URLSession = .shared) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = appSupport.appendingPathComponent("HyperBrowser/FilterLists", isDirectory: true)
        }
        self.session = session
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// Cached texts for the given sources, in source order; sources that have
    /// never been downloaded are skipped.
    public func cachedListTexts(for sources: [FilterListSource]) -> [String] {
        sources.compactMap { try? String(contentsOf: listURL(for: $0), encoding: .utf8) }
    }

    /// Checks each source for a newer version. Returns `true` if at least one
    /// list changed on disk (meaning rules should be rebuilt).
    public func refresh(_ sources: [FilterListSource], minimumInterval: TimeInterval = 24 * 3600, force: Bool = false) async -> Bool {
        var anyChanged = false
        for source in sources {
            var metadata = loadMetadata(for: source)
            if !force, let last = metadata.lastChecked, Date().timeIntervalSince(last) < minimumInterval,
               FileManager.default.fileExists(atPath: listURL(for: source).path) {
                continue
            }

            var request = URLRequest(url: source.url)
            request.timeoutInterval = 60
            if FileManager.default.fileExists(atPath: listURL(for: source).path) {
                if let etag = metadata.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
                if let modified = metadata.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
            }

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                switch http.statusCode {
                case 304:
                    metadata.lastChecked = Date()
                    saveMetadata(metadata, for: source)
                case 200:
                    guard let text = String(data: data, encoding: .utf8), Self.isPlausibleFilterList(text) else {
                        Log.network.error("Rejected implausible filter list from \(source.name, privacy: .public)")
                        continue
                    }
                    try data.write(to: listURL(for: source), options: .atomic)
                    metadata.etag = http.value(forHTTPHeaderField: "ETag")
                    metadata.lastModified = http.value(forHTTPHeaderField: "Last-Modified")
                    metadata.lastChecked = Date()
                    saveMetadata(metadata, for: source)
                    anyChanged = true
                default:
                    Log.network.error("Filter list \(source.name, privacy: .public) returned HTTP \(http.statusCode)")
                }
            } catch {
                Log.network.error("Filter list \(source.name, privacy: .public) update failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return anyChanged
    }

    /// Guards against an error page, captive-portal login or truncated body
    /// silently replacing a working list with garbage.
    static func isPlausibleFilterList(_ text: String) -> Bool {
        guard text.count > 1000 else { return false }
        if text.prefix(300).contains("[Adblock") { return true }
        return text.split(separator: "\n", maxSplits: 200, omittingEmptySubsequences: true).count > 100
    }

    private func listURL(for source: FilterListSource) -> URL {
        directory.appendingPathComponent("\(source.name).txt")
    }

    private func metadataURL(for source: FilterListSource) -> URL {
        directory.appendingPathComponent("\(source.name).meta.json")
    }

    private func loadMetadata(for source: FilterListSource) -> Metadata {
        guard let data = try? Data(contentsOf: metadataURL(for: source)),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data) else { return Metadata() }
        return metadata
    }

    private func saveMetadata(_ metadata: Metadata, for source: FilterListSource) {
        if let data = try? JSONEncoder().encode(metadata) {
            try? data.write(to: metadataURL(for: source), options: .atomic)
        }
    }
}
