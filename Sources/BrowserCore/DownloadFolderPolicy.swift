import Foundation

public enum DownloadFolderPolicy {
    /// The folder to save into: the chosen one if it still exists and can be written to, else `fallback` (a folder that was deleted or whose
    /// disk was unplugged must not make downloads fail).
    public static func directory(chosenPath: String, fallback: URL, fileManager: FileManager = .default) -> URL {
        let path = chosenPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return fallback }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue, fileManager.isWritableFile(atPath: path) else { return fallback }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
