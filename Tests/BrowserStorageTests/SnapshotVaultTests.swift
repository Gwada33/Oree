import Testing
import Foundation
@testable import BrowserStorage

@Suite struct SnapshotVaultTests {
    private func makeVault(key: Data = Data(repeating: 7, count: 32)) -> (SnapshotVault, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        return (SnapshotVault(directory: dir, keys: StaticKeyProvider(data: key)), dir)
    }

    @Test func putThenGetReturnsThePicture() throws {
        let (vault, dir) = makeVault(); defer { try? FileManager.default.removeItem(at: dir) }
        let picture = Data("pixels".utf8)
        try vault.put(picture, for: "https://example.com/a")
        #expect(vault.get(for: "https://example.com/a") == picture)
        #expect(vault.get(for: "https://example.com/b") == nil)
    }

    @Test func nothingReadableIsWrittenToDisk() throws {
        let (vault, dir) = makeVault(); defer { try? FileManager.default.removeItem(at: dir) }
        try vault.put(Data("SECRET-PIXELS".utf8), for: "https://bank.example/account")
        for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            #expect(!url.lastPathComponent.contains("bank"))
            #expect(try Data(contentsOf: url).range(of: Data("SECRET-PIXELS".utf8)) == nil)
        }
    }

    @Test func aDifferentKeyCannotReadIt() throws {
        let (vault, dir) = makeVault(); defer { try? FileManager.default.removeItem(at: dir) }
        try vault.put(Data("pixels".utf8), for: "https://example.com")
        let other = SnapshotVault(directory: dir, keys: StaticKeyProvider(data: Data(repeating: 9, count: 32)))
        #expect(other.get(for: "https://example.com") == nil)
    }

    @Test func pruneKeepsOnlyTheOpenTabs() throws {
        let (vault, dir) = makeVault(); defer { try? FileManager.default.removeItem(at: dir) }
        try vault.put(Data("1".utf8), for: "https://keep.example")
        try vault.put(Data("2".utf8), for: "https://closed.example")
        vault.prune(keeping: ["https://keep.example"])
        #expect(vault.get(for: "https://keep.example") != nil)
        #expect(vault.get(for: "https://closed.example") == nil)
    }
}
