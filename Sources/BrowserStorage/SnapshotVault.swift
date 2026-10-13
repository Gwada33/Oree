import Foundation
import CryptoKit

/// Picture of a sleeping tab, kept between two launches so a restored tab does not come back as a blank page while it loads.
///
/// Privacy: the picture is a screenshot of a page, so it is encrypted (ChaCha20-Poly1305, key in the Keychain), named by a hash of the
/// address (nothing readable on disk), and everything that no longer belongs to an open tab is removed at each quit. Private tabs never
/// get here (the caller only passes savable tabs).
public struct SnapshotVault: Sendable {
    private let directory: URL
    private let keys: VaultKeyProvider

    public init(directory: URL, keys: VaultKeyProvider) {
        self.directory = directory
        self.keys = keys
    }

    /// The app's vault: `Caches/Orée/SleepSnapshots`, Keychain key `com.nolhan.hyperbrowser.snapshots`.
    public static let shared: SnapshotVault = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Orée/SleepSnapshots", isDirectory: true)
        return SnapshotVault(directory: base, keys: KeychainKeyProvider(service: "com.nolhan.hyperbrowser.snapshots", account: "snapshot-key"))
    }()

    private func file(for address: String) -> URL {
        let name = SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".snap")
    }

    public func put(_ picture: Data, for address: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sealed = try ChaChaPoly.seal(picture, using: keys.masterKey())
        try sealed.combined.write(to: file(for: address), options: [.atomic, .completeFileProtection])
    }

    /// nil when there is none, or when it cannot be read (wrong key, damaged file): never an error for the caller.
    public func get(for address: String) -> Data? {
        guard let blob = try? Data(contentsOf: file(for: address)),
              let box = try? ChaChaPoly.SealedBox(combined: blob),
              let key = try? keys.masterKey() else { return nil }
        return try? ChaChaPoly.open(box, using: key)
    }

    /// Removes every picture whose address is not in `addresses`.
    public func prune(keeping addresses: Set<String>) {
        let keep = Set(addresses.map { file(for: $0).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where !keep.contains(url.lastPathComponent) { try? FileManager.default.removeItem(at: url) }
    }
}
