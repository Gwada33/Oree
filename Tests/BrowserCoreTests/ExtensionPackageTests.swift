import Testing
import Foundation
@testable import BrowserCore

struct ExtensionPackageTests {
    private func temp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hb-ext-\(name)-\(UUID().uuidString)")
    }

    private func le(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }

    @Test func crx3PayloadIsAfterTheHeader() throws {
        let payload: [UInt8] = [0x50, 0x4B, 3, 4, 9, 9]
        let data = Data(Array("Cr24".utf8) + le(3) + le(5) + [1, 2, 3, 4, 5] + payload)
        #expect(try ExtensionPackage.zipPayload(fromCRX: data) == Data(payload))
    }

    @Test func crx2PayloadIsAfterKeyAndSignature() throws {
        let payload: [UInt8] = [0x50, 0x4B, 7, 7]
        let data = Data(Array("Cr24".utf8) + le(2) + le(3) + le(2) + [1, 1, 1] + [2, 2] + payload)
        #expect(try ExtensionPackage.zipPayload(fromCRX: data) == Data(payload))
    }

    @Test func notACRXIsRejected() {
        #expect(throws: ExtensionPackageError.badCRX) { try ExtensionPackage.zipPayload(fromCRX: Data("PK not a crx at all, long enough".utf8)) }
        #expect(throws: ExtensionPackageError.badCRX) { try ExtensionPackage.zipPayload(fromCRX: Data(Array("Cr24".utf8) + le(9) + [0, 0, 0, 0, 0, 0, 0, 0, 0])) }
    }

    @Test func folderWithManifestIsCopied() throws {
        let source = temp("src"), destination = temp("dst")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: destination) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appendingPathComponent("manifest.json"))
        let root = try ExtensionPackage.unpack(source, to: destination)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path))
    }

    @Test func folderWithoutManifestIsRejected() throws {
        let source = temp("src"), destination = temp("dst")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: destination) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: source.appendingPathComponent("readme.txt"))
        #expect(throws: ExtensionPackageError.notAnExtension) { try ExtensionPackage.unpack(source, to: destination) }
    }

    @Test func zipWithATopLevelFolderIsUnwrapped() throws {
        let work = temp("zip"), destination = temp("dst")
        defer { try? FileManager.default.removeItem(at: work); try? FileManager.default.removeItem(at: destination) }
        let inner = work.appendingPathComponent("my-extension")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: inner.appendingPathComponent("manifest.json"))
        let archive = work.appendingPathComponent("ext.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = work
        zip.arguments = ["-qr", "ext.zip", "my-extension"]
        try zip.run(); zip.waitUntilExit()
        let root = try ExtensionPackage.unpack(archive, to: destination)
        #expect(root.lastPathComponent == "my-extension")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path))
    }
}
