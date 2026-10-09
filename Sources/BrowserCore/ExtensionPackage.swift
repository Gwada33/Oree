import Foundation

public enum ExtensionPackageError: Error, Equatable {
    case notAnExtension          // no manifest.json
    case badCRX
    case unpackFailed
    case unsafeContents          // something would land outside the destination
}

/// Turns what the user picks (an unpacked folder, a .zip, a Chrome .crx) into an unpacked
/// extension folder with `manifest.json` at its root.
public enum ExtensionPackage {
    /// The ZIP inside a Chrome extension file. CRX3 = "Cr24", 3, header length, header, zip;
    /// CRX2 = "Cr24", 2, key length, signature length, key, signature, zip.
    public static func zipPayload(fromCRX data: Data) throws -> Data {
        let bytes = [UInt8](data)
        func word(_ offset: Int) -> Int? {
            guard bytes.count >= offset + 4 else { return nil }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        guard bytes.count > 16, Array(bytes[0..<4]) == Array("Cr24".utf8), let version = word(4) else { throw ExtensionPackageError.badCRX }
        let start: Int
        switch version {
        case 3:
            guard let headerLength = word(8) else { throw ExtensionPackageError.badCRX }
            start = 12 + headerLength
        case 2:
            guard let keyLength = word(8), let signatureLength = word(12) else { throw ExtensionPackageError.badCRX }
            start = 16 + keyLength + signatureLength
        default:
            throw ExtensionPackageError.badCRX
        }
        guard start < bytes.count else { throw ExtensionPackageError.badCRX }
        return Data(bytes[start...])
    }

    /// Unpacks `source` into a fresh `destination` directory and returns the folder that holds `manifest.json`.
    @discardableResult
    public static func unpack(_ source: URL, to destination: URL) throws -> URL {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else { throw ExtensionPackageError.notAnExtension }

        if isDirectory.boolValue {
            for item in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try fileManager.copyItem(at: item, to: destination.appendingPathComponent(item.lastPathComponent))
            }
        } else {
            var archive = source
            if source.pathExtension.lowercased() == "crx" {
                let zip = try zipPayload(fromCRX: Data(contentsOf: source))
                archive = destination.appendingPathComponent(".package.zip")
                try zip.write(to: archive)
            }
            try extract(archive, into: destination)
            if archive.lastPathComponent == ".package.zip" { try? fileManager.removeItem(at: archive) }
        }

        try verifyContained(in: destination)
        return try rootContainingManifest(in: destination)
    }

    private static func extract(_ archive: URL, into destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ExtensionPackageError.unpackFailed }
    }

    /// Nothing extracted may resolve outside the destination (zip-slip, symlinks pointing out).
    private static func verifyContained(in directory: URL) throws {
        let base = directory.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker {
            let resolved = url.resolvingSymlinksInPath().path
            guard resolved == base || resolved.hasPrefix(base + "/") else { throw ExtensionPackageError.unsafeContents }
        }
    }

    /// Zips often wrap everything in one top-level folder; accept both layouts.
    private static func rootContainingManifest(in directory: URL) throws -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) { return directory }
        let entries = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
        if entries.count == 1, fileManager.fileExists(atPath: entries[0].appendingPathComponent("manifest.json").path) { return entries[0] }
        throw ExtensionPackageError.notAnExtension
    }
}

/// What the settings screen shows about an installed extension.
public struct ExtensionInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let summary: String
    public var isEnabled: Bool

    public init(id: String, name: String, version: String, summary: String, isEnabled: Bool) {
        self.id = id; self.name = name; self.version = version; self.summary = summary; self.isEnabled = isEnabled
    }
}

/// Implemented by the browser; used by the settings screen.
@MainActor
public protocol ExtensionsProviding: AnyObject {
    func installedExtensions() -> [ExtensionInfo]
    func install(from url: URL) async throws
    func setEnabled(_ enabled: Bool, id: String)
    func remove(id: String)
}
