import Foundation
import CryptoKit
import BrowserCore

/// Picture of a sleeping tab, kept between two launches so a restored tab does not come back as a blank page while it loads.
///
/// Privacy: the picture is a screenshot of a page, so it is encrypted (ChaCha20-Poly1305, key in the Keychain), named by a hash of the
/// address (nothing readable on disk), and everything that no longer belongs to an open tab is removed at each quit. Private tabs never
/// get here (the caller only passes savable tabs).
public struct SnapshotVault: Sendable {
    private let directory: URL
    private let keys: VaultKeyProvider
    /// One Keychain read per launch, not one per tab (30 restored tabs would mean 30 reads on the main thread).
    private let cache = KeyCache()

    private final class KeyCache: @unchecked Sendable {
        private let lock = NSLock()
        private var key: SymmetricKey?
        func get(_ provider: VaultKeyProvider) throws -> SymmetricKey {
            lock.lock(); defer { lock.unlock() }
            if let key { return key }
            let fresh = try provider.masterKey(); key = fresh; return fresh
        }
    }

    public init(directory: URL, keys: VaultKeyProvider) {
        self.directory = directory
        self.keys = keys
    }

    /// The app's vault: `Caches/Orée/SleepSnapshots`, Keychain key `com.nolhan.hyperbrowser.snapshots`.
    public static let shared: SnapshotVault = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("\(ProfileContext.cachesFolderName)/SleepSnapshots", isDirectory: true)
        return SnapshotVault(directory: base, keys: KeychainKeyProvider(service: "com.nolhan.hyperbrowser.snapshots", account: "snapshot-key"))
    }()

    private func file(for address: String) -> URL {
        let name = SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".snap")
    }

    public func put(_ picture: Data, for address: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sealed = try ChaChaPoly.seal(picture, using: cache.get(keys))
        try sealed.combined.write(to: file(for: address), options: [.atomic, .completeFileProtection])
    }

    /// nil when there is none, or when it cannot be read (wrong key, damaged file): never an error for the caller.
    public func get(for address: String) -> Data? {
        guard let blob = try? Data(contentsOf: file(for: address)),
              let box = try? ChaChaPoly.SealedBox(combined: blob),
              let key = try? cache.get(keys) else { return nil }
        return try? ChaChaPoly.open(box, using: key)
    }

    /// Removes every picture whose address is not in `addresses`.
    public func prune(keeping addresses: Set<String>) {
        let keep = Set(addresses.map { file(for: $0).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where !keep.contains(url.lastPathComponent) { try? FileManager.default.removeItem(at: url) }
    }
}
