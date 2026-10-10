import AppKit
import CryptoKit
import BrowserCore

/// Self-update from GitHub Releases: checks the latest release, and on approval downloads the zip,
/// swaps the app in place and relaunches — no reinstall by hand. Nothing is sent but the request itself
/// (no identifier, no telemetry); the automatic check can be turned off in the settings.
@MainActor
final class AppUpdater {
    static let shared = AppUpdater()
    private var isBusy = false
    private static let lastCheckKey = "update.lastCheck"

    private var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    /// At launch: at most once a day, silent unless a newer version exists.
    func checkInBackgroundIfDue() {
        guard SettingsStore.shared.autoUpdateCheck else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        Task { await check(userInitiated: false) }
    }

    /// Menu "Rechercher des mises à jour…": always answers, even "you're up to date".
    func checkNow() { Task { await check(userInitiated: true) } }

    private func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        var request = URLRequest(url: UpdateChecker.latestReleaseURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = UpdateChecker.parse(data) else {
            if userInitiated { alert("Impossible de vérifier les mises à jour", "Vérifiez votre connexion, ou qu'une version est bien publiée.") }
            return
        }
        guard UpdateChecker.isNewer(release.version, than: currentVersion) else {
            if userInitiated { alert("Orée est à jour", "Version \(currentVersion).") }
            return
        }
        let ask = NSAlert()
        ask.messageText = "Orée \(release.version) est disponible"
        ask.informativeText = (release.notes.isEmpty ? "" : String(release.notes.prefix(600)) + "\n\n") + "Vous avez la version \(currentVersion). Orée va se fermer puis se relancer."
        ask.addButton(withTitle: "Installer et relancer")
        ask.addButton(withTitle: "Plus tard")
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        await install(release)
    }

    private func install(_ release: ReleaseInfo) async {
        let destination = Bundle.main.bundleURL
        let parent = destination.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else {
            alert("Installation impossible", "Orée n'a pas le droit d'écrire dans « \(parent) ». Déplacez l'app dans Applications, ou mettez-la à jour à la main.")
            return
        }
        do {
            // The release must publish a SHA-256 next to the zip, and the zip must match it: the bundle identifier
            // alone says nothing about who built the file.
            guard let checksumURL = release.checksumURL,
                  let (checksumData, _) = try? await URLSession.shared.data(from: checksumURL),
                  let expected = UpdateChecker.parseChecksum(String(decoding: checksumData, as: UTF8.self)) else {
                throw UpdateError.noChecksum
            }
            let (zip, _) = try await URLSession.shared.download(from: release.downloadURL)
            let digest = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
            guard digest == expected else { throw UpdateError.checksumMismatch }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("oree-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let staged = work.appendingPathComponent("zip.zip")
            try FileManager.default.moveItem(at: zip, to: staged)
            guard try await Self.run("/usr/bin/ditto", ["-x", "-k", staged.path, work.path]) == 0,
                  let app = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            // Same bundle identifier or it isn't ours: refuse to install a foreign app.
            guard Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else { throw CocoaError(.fileReadCorruptFile) }
            try relaunchReplacing(destination, with: app)
        } catch {
            alert("La mise à jour a échoué", "Orée reste en version \(currentVersion). (\(error.localizedDescription))")
        }
    }

    /// A tiny detached script waits for this process to quit, swaps the bundles and reopens the app.
    private func relaunchReplacing(_ destination: URL, with new: URL) throws {
        let script = new.deletingLastPathComponent().appendingPathComponent("swap.sh")
        let q = { (url: URL) in "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        try """
        #!/bin/bash
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
        old=\(q(destination)).old
        rm -rf "$old"
        mv \(q(destination)) "$old" && mv \(q(new)) \(q(destination)) && rm -rf "$old" || { [ -d "$old" ] && mv "$old" \(q(destination)); }
        xattr -dr com.apple.quarantine \(q(destination)) 2>/dev/null
        open \(q(destination))
        """.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        NSApp.terminate(nil)
    }

    private static func run(_ path: String, _ arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private enum UpdateError: LocalizedError {
        case noChecksum, checksumMismatch
        var errorDescription: String? {
            switch self {
            case .noChecksum: "cette version ne publie pas d'empreinte de vérification"
            case .checksumMismatch: "l'empreinte du fichier téléchargé ne correspond pas"
            }
        }
    }

    private func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = text
        alert.runModal()
    }
}
