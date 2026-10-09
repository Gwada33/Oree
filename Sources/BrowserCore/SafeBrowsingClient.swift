import Foundation

/// Network seam so the client can be tested without Google.
public protocol SafeBrowsingTransport: Sendable {
    /// POSTs `body` as JSON to `endpoint` (e.g. "threatListUpdates:fetch") and returns the JSON reply.
    func post(endpoint: String, body: Data) async throws -> Data
}

public struct URLSessionSafeBrowsingTransport: SafeBrowsingTransport {
    let apiKey: String
    public init(apiKey: String) { self.apiKey = apiKey }

    public func post(endpoint: String, body: Data) async throws -> Data {
        var components = URLComponents(string: "https://safebrowsing.googleapis.com/v4/\(endpoint)")!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}

public enum ThreatKind: String, CaseIterable, Sendable {
    case malware = "MALWARE"
    case socialEngineering = "SOCIAL_ENGINEERING"
    case unwantedSoftware = "UNWANTED_SOFTWARE"

    public var userDescription: String {
        switch self {
        case .malware: return "un site de logiciels malveillants"
        case .socialEngineering: return "un site d'hameçonnage"
        case .unwantedSoftware: return "un site de logiciels indésirables"
        }
    }
}

/// Google Safe Browsing v4 (Update API). The browser keeps hash prefixes
/// locally; a URL with no local prefix match never touches the network.
/// Only on a prefix hit is the 4-byte prefix sent to ask for full hashes,
/// and the answer is verified locally against our own expressions.
public actor SafeBrowsingClient {
    private let transport: SafeBrowsingTransport
    private let directory: URL?
    private let now: @Sendable () -> Date

    private var stores: [ThreatKind: HashPrefixStore] = [:]
    private var states: [ThreatKind: String] = [:]
    private var nextUpdateAllowed = Date.distantPast
    private var failures = 0
    /// full hash -> (threat, expiry), positive cache honouring `cacheDuration`.
    private var positive: [Data: (ThreatKind, Date)] = [:]
    private var negativeUntil: [Data: Date] = [:]
    private var nextFindAllowed = Date.distantPast

    public init(transport: SafeBrowsingTransport, directory: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.directory = directory
        self.now = now
        if let directory {
            (stores, states) = Self.load(from: directory)
        }
    }

    // MARK: Update

    /// Fetches list updates unless the server asked us to wait. Returns false if skipped or failed.
    @discardableResult
    public func updateLists() async -> Bool {
        guard now() >= nextUpdateAllowed else { return false }
        let requests: [[String: Any]] = ThreatKind.allCases.map { kind in
            [
                "threatType": kind.rawValue, "platformType": "ANY_PLATFORM", "threatEntryType": "URL",
                "state": states[kind] ?? "",
                "constraints": ["supportedCompressions": ["RAW"]],
            ]
        }
        let body: [String: Any] = [
            "client": ["clientId": "hyperbrowser", "clientVersion": "1.0"],
            "listUpdateRequests": requests,
        ]
        do {
            let data = try await transport.post(endpoint: "threatListUpdates:fetch", body: JSONSerialization.data(withJSONObject: body))
            try apply(updateResponse: data)
            failures = 0
            saveToDisk()
            return true
        } catch {
            failures += 1
            // Exponential backoff with a 24h cap, per the Safe Browsing guidelines.
            nextUpdateAllowed = now().addingTimeInterval(min(pow(2, Double(failures)) * 60, 86_400))
            Log.security.error("Safe Browsing update failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func apply(updateResponse data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        if let wait = root["minimumWaitDuration"] as? String, let seconds = Self.seconds(wait) {
            nextUpdateAllowed = now().addingTimeInterval(seconds)
        }
        var newStores = stores, newStates = states
        for response in root["listUpdateResponses"] as? [[String: Any]] ?? [] {
            guard let type = response["threatType"] as? String, let kind = ThreatKind(rawValue: type) else { continue }
            var store = newStores[kind] ?? HashPrefixStore()
            if response["responseType"] as? String == "FULL_UPDATE" { store.removeAll() }

            var removals: [Int] = []
            for removal in response["removals"] as? [[String: Any]] ?? [] {
                removals += ((removal["rawIndices"] as? [String: Any])?["indices"] as? [Int]) ?? []
            }
            var additions: [HashPrefixStore.Addition] = []
            for addition in response["additions"] as? [[String: Any]] ?? [] {
                guard let raw = addition["rawHashes"] as? [String: Any],
                      let size = raw["prefixSize"] as? Int,
                      let b64 = raw["rawHashes"] as? String, let bytes = Data(base64Encoded: b64) else { continue }
                additions.append(.init(prefixSize: size, rawHashes: [UInt8](bytes)))
            }
            var checksum: Data?
            if let sha = (response["checksum"] as? [String: Any])?["sha256"] as? String { checksum = Data(base64Encoded: sha) }

            do {
                try store.apply(removalIndices: removals.sorted(), additions: additions, expectedChecksum: checksum)
            } catch {
                // Corrupt/mismatched: drop this list and its state so the next fetch is a full update.
                newStores[kind] = nil; newStates[kind] = nil
                throw error
            }
            newStores[kind] = store
            if let state = response["newClientState"] as? String { newStates[kind] = state }
        }
        stores = newStores; states = newStates
    }

    // MARK: Lookup

    /// Checks a URL. Returns the threat if confirmed by a full-hash match.
    public func check(_ url: URL) async -> ThreatKind? {
        let hashed = SafeBrowsingURL.hashedExpressions(for: url)
        let current = now()
        positive = positive.filter { $0.value.1 > current }
        negativeUntil = negativeUntil.filter { $0.value > current }

        var unresolved: [(hash: Data, prefix: Data)] = []
        for (_, hash) in hashed {
            if let hit = positive[hash] { return hit.0 }
            if negativeUntil[hash] != nil { continue }
            for store in stores.values {
                if let prefix = store.matchingPrefix(of: hash) { unresolved.append((hash, prefix)); break }
            }
        }
        guard !unresolved.isEmpty, current >= nextFindAllowed else { return nil }

        let prefixes = Set(unresolved.map(\.prefix))
        let body: [String: Any] = [
            "client": ["clientId": "hyperbrowser", "clientVersion": "1.0"],
            "clientStates": ThreatKind.allCases.compactMap { states[$0] },
            "threatInfo": [
                "threatTypes": ThreatKind.allCases.map(\.rawValue),
                "platformTypes": ["ANY_PLATFORM"],
                "threatEntryTypes": ["URL"],
                "threatEntries": prefixes.map { ["hash": $0.base64EncodedString()] },
            ],
        ]
        guard let data = try? await transport.post(endpoint: "fullHashes:find", body: JSONSerialization.data(withJSONObject: body)),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        if let wait = root["minimumWaitDuration"] as? String, let s = Self.seconds(wait) { nextFindAllowed = now().addingTimeInterval(s) }
        let negative = (root["negativeCacheDuration"] as? String).flatMap(Self.seconds) ?? 300
        let ours = Set(unresolved.map(\.hash))
        var found: ThreatKind?
        for match in root["matches"] as? [[String: Any]] ?? [] {
            guard let hashB64 = (match["threat"] as? [String: Any])?["hash"] as? String,
                  let full = Data(base64Encoded: hashB64), ours.contains(full),   // local verification
                  let type = match["threatType"] as? String, let kind = ThreatKind(rawValue: type) else { continue }
            let ttl = (match["cacheDuration"] as? String).flatMap(Self.seconds) ?? 300
            positive[full] = (kind, now().addingTimeInterval(ttl))
            found = found ?? kind
        }
        for hash in ours where positive[hash] == nil { negativeUntil[hash] = now().addingTimeInterval(negative) }
        return found
    }

    public var prefixCount: Int { stores.values.reduce(0) { $0 + $1.count } }

    // MARK: Helpers & persistence

    static func seconds(_ duration: String) -> TimeInterval? {
        guard duration.hasSuffix("s") else { return nil }
        return TimeInterval(duration.dropLast())
    }

    private static func load(from directory: URL) -> ([ThreatKind: HashPrefixStore], [ThreatKind: String]) {
        var stores: [ThreatKind: HashPrefixStore] = [:], states: [ThreatKind: String] = [:]
        for kind in ThreatKind.allCases {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(kind.rawValue).bin")),
                  let store = HashPrefixStore(serialized: data),
                  let state = try? String(contentsOf: directory.appendingPathComponent("\(kind.rawValue).state"), encoding: .utf8)
            else { continue }
            stores[kind] = store; states[kind] = state
        }
        return (stores, states)
    }

    private func saveToDisk() {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for kind in ThreatKind.allCases {
            guard let store = stores[kind], let state = states[kind] else { continue }
            try? store.serialized().write(to: directory.appendingPathComponent("\(kind.rawValue).bin"), options: .atomic)
            try? state.write(to: directory.appendingPathComponent("\(kind.rawValue).state"), atomically: true, encoding: .utf8)
        }
    }
}
