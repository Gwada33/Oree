import Foundation

/// Registers the downloader as a per-user launchd agent so downloads outlive the browser.
/// Works with an ad-hoc signed app (no SMAppService needed): a plist in ~/Library/LaunchAgents plus
/// `launchctl bootstrap gui/<uid>`. launchd starts the process on demand (first XPC message).
public enum AgentInstaller {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(DownloaderService.machName).plist")
    }

    /// The agent's launchd description. `executable` is the helper inside the app bundle.
    public static func plist(executable: URL, bundleIdentifier: String, logPath: String) -> [String: Any] {
        [
            "Label": DownloaderService.machName,
            "ProgramArguments": [executable.path, "--agent"],
            "MachServices": [DownloaderService.machName: true],
            "RunAtLoad": false,
            "KeepAlive": false,
            "ProcessType": "Adaptive",
            "AssociatedBundleIdentifiers": [bundleIdentifier],     // shown under the app's name in Login Items
            "StandardErrorPath": logPath,
            "StandardOutPath": logPath,
        ]
    }

    /// Makes sure launchd knows the agent and that it points at this copy of the app. Safe to call at every launch.
    @discardableResult
    public static func ensureInstalled(executable: URL, bundleIdentifier: String) throws -> Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: executable.path) else { throw Failure(message: "exécutable introuvable : \(executable.path)") }
        let logs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Orée", isDirectory: true)
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let desired = plist(executable: executable, bundleIdentifier: bundleIdentifier, logPath: logs.appendingPathComponent("downloader.log").path)
        let desiredData = try PropertyListSerialization.data(fromPropertyList: desired, format: .xml, options: 0)

        let existing = try? Data(contentsOf: plistURL)
        let loaded = isLoaded()
        if existing == desiredData, loaded { return false }          // nothing to do

        try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if loaded { _ = launchctl(["bootout", "gui/\(getuid())/\(DownloaderService.machName)"]) }
        try desiredData.write(to: plistURL, options: .atomic)
        let result = launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        guard result.status == 0 || isLoaded() else { throw Failure(message: "launchctl bootstrap a échoué (\(result.status)) : \(result.output)") }
        return true
    }

    public static func uninstall() {
        _ = launchctl(["bootout", "gui/\(getuid())/\(DownloaderService.machName)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    public static func isLoaded() -> Bool {
        launchctl(["print", "gui/\(getuid())/\(DownloaderService.machName)"]).status == 0
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, output)
    }
}
