import Foundation

/// Enregistre le service IA comme agent launchd de l'utilisateur, démarré à la demande par le premier message XPC.
/// Même méthode que `AgentInstaller` du téléchargeur : un plist dans ~/Library/LaunchAgents puis `launchctl bootstrap`.
public enum AIAgentInstaller {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func plistURL(machName: String = OreeAIServiceInfo.machName) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(machName).plist")
    }

    /// Description launchd de l'agent. `executable` est l'exécutable `OreeAI` dans le bundle de l'app.
    public static func plist(executable: URL, bundleIdentifier: String, logPath: String, machName: String = OreeAIServiceInfo.machName) -> [String: Any] {
        var arguments = [executable.path, "--agent"]
        if machName != OreeAIServiceInfo.machName { arguments += ["--mach-name", machName] }
        return [
            "Label": machName,
            "ProgramArguments": arguments,
            "MachServices": [machName: true],
            "RunAtLoad": false,
            "KeepAlive": false,
            "ProcessType": "Adaptive",
            "AssociatedBundleIdentifiers": [bundleIdentifier],
            "StandardErrorPath": logPath,
            "StandardOutPath": logPath,
        ]
    }

    /// Fait en sorte que launchd connaisse l'agent et qu'il pointe vers cette copie de l'app. Sans danger à chaque lancement.
    @discardableResult
    public static func ensureInstalled(executable: URL, bundleIdentifier: String, machName: String = OreeAIServiceInfo.machName) throws -> Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: executable.path) else { throw Failure(message: "exécutable introuvable : \(executable.path)") }
        let logs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Orée", isDirectory: true)
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let desired = plist(executable: executable, bundleIdentifier: bundleIdentifier, logPath: logs.appendingPathComponent("ai.log").path, machName: machName)
        let desiredData = try PropertyListSerialization.data(fromPropertyList: desired, format: .xml, options: 0)
        let url = plistURL(machName: machName)

        let loaded = isLoaded(machName: machName)
        if (try? Data(contentsOf: url)) == desiredData, loaded { return false }

        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if loaded { _ = launchctl(["bootout", "gui/\(getuid())/\(machName)"]) }
        try desiredData.write(to: url, options: .atomic)
        let result = launchctl(["bootstrap", "gui/\(getuid())", url.path])
        guard result.status == 0 || isLoaded(machName: machName) else { throw Failure(message: "launchctl bootstrap a échoué (\(result.status)) : \(result.output)") }
        return true
    }

    public static func uninstall(machName: String = OreeAIServiceInfo.machName) {
        _ = launchctl(["bootout", "gui/\(getuid())/\(machName)"])
        try? FileManager.default.removeItem(at: plistURL(machName: machName))
    }

    public static func isLoaded(machName: String = OreeAIServiceInfo.machName) -> Bool {
        launchctl(["print", "gui/\(getuid())/\(machName)"]).status == 0
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
        return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
