import Foundation
import WebKit
import CryptoKit
import AdblockBridge

/// Per-page cosmetic filtering (hiding ad containers). Backed by the Rust
/// engine, which is internally synchronized, so lookups are safe from any thread.
public final class CosmeticFilterService: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: CosmeticEngine?

    public init() {}

    public func load(listTexts: [String]) async {
        // Building the engine parses every list — keep it off the main thread.
        let built = await Task.detached(priority: .utility) { CosmeticEngine(listTexts: listTexts) }.value
        lock.withLock { engine = built }
    }

    public func css(for url: URL) -> String {
        let current = lock.withLock { engine }
        return current?.cssForUrl(url: url.absoluteString) ?? ""
    }
}

/// Owns the compiled content-blocking rule lists: loads them from cache at
/// launch, rebuilds them when the downloaded lists change, and tells the UI
/// whenever the active set changes.
@MainActor
public final class ContentBlockerManager {
    /// WebKit rejects a single rule list above 150 000 rules; leave headroom.
    nonisolated static let maxRulesPerList: UInt32 = 140_000
    nonisolated static let identifierPrefix = "HBFilter-"

    private struct Manifest: Codable {
        let version: String
        let identifiers: [String]
    }

    public private(set) var ruleLists: [WKContentRuleList] = []
    public let cosmetic = CosmeticFilterService()
    public var onRuleListsChanged: (([WKContentRuleList]) -> Void)?

    private let store: FilterListStore
    private let sources: [FilterListSource]
    private let manifestURL: URL
    private var updateTask: Task<Void, Never>?

    public init(store: FilterListStore = FilterListStore(), sources: [FilterListSource] = FilterListSource.defaults) {
        self.store = store
        self.sources = sources
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        manifestURL = appSupport.appendingPathComponent("HyperBrowser/FilterLists/manifest.json")
    }

    deinit { updateTask?.cancel() }

    /// Applies whatever protection is available immediately (cached lists, or
    /// the baseline), then keeps the lists fresh in the background.
    public func start() {
        updateTask = Task { [weak self] in
            guard let self else { return }
            await self.applyCachedOrBaseline()
            while !Task.isCancelled {
                if await self.store.refresh(self.sources) {
                    await self.rebuild()
                }
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    /// Forces a download + rebuild now (Settings → "Update lists").
    public func updateNow() async {
        if await store.refresh(sources, force: true) {
            await rebuild()
        }
    }

    private func applyCachedOrBaseline() async {
        let cached = await store.cachedListTexts(for: sources)
        if cached.isEmpty {
            if let baseline = await BaselineBlocklist.compile() { publish([baseline]) }
        } else {
            await rebuild()
        }
    }

    private func rebuild() async {
        let texts = await store.cachedListTexts(for: sources)
        guard !texts.isEmpty else { return }
        let version = Self.version(of: texts)
        let ruleStore: WKContentRuleListStore = WKContentRuleListStore.default()

        async let cosmeticReady: Void = cosmetic.load(listTexts: texts)

        if let manifest = readManifest(), manifest.version == version {
            var restored: [WKContentRuleList] = []
            for identifier in manifest.identifiers {
                if let list = try? await ruleStore.contentRuleList(forIdentifier: identifier) { restored.append(list) }
            }
            if restored.count == manifest.identifiers.count, !restored.isEmpty {
                publish(restored)
                await cosmeticReady
                return
            }
        }

        let chunks: [String]
        do {
            chunks = try await Task.detached(priority: .utility) {
                try convertToContentBlocking(listTexts: texts, maxRulesPerChunk: ContentBlockerManager.maxRulesPerList)
            }.value
        } catch {
            Log.network.error("Filter list conversion failed: \(error.localizedDescription, privacy: .public)")
            await cosmeticReady
            return
        }

        var compiled: [WKContentRuleList] = []
        var identifiers: [String] = []
        for (index, json) in chunks.enumerated() {
            let identifier = "\(Self.identifierPrefix)\(version)-\(index)"
            do {
                if let list = try await ruleStore.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) {
                    compiled.append(list)
                    identifiers.append(identifier)
                }
            } catch {
                Log.network.error("Compiling rule list \(index) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if !compiled.isEmpty {
            publish(compiled)
            // Only a *complete* set is cached: restoring a partial one next
            // launch would silently under-block.
            if compiled.count == chunks.count { writeManifest(Manifest(version: version, identifiers: identifiers)) }
            await removeStaleLists(keeping: Set(identifiers))
        }
        await cosmeticReady
    }

    private func publish(_ lists: [WKContentRuleList]) {
        ruleLists = lists
        onRuleListsChanged?(lists)
    }

    private func removeStaleLists(keeping keep: Set<String>) async {
        let ruleStore: WKContentRuleListStore = WKContentRuleListStore.default()
        for identifier in await ruleStore.availableIdentifiers() ?? [] where identifier.hasPrefix(Self.identifierPrefix) && !keep.contains(identifier) {
            try? await ruleStore.removeContentRuleList(forIdentifier: identifier)
        }
    }

    static func version(of texts: [String]) -> String {
        var hasher = SHA256()
        for text in texts { hasher.update(data: Data(text.utf8)) }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func readManifest() -> Manifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    private func writeManifest(_ manifest: Manifest) {
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }
}
