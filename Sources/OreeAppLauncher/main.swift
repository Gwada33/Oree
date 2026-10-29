import AppKit

/// Le raccourci d'une application d'Orée (un petit .app rangé dans Applications). Il ne montre rien lui-même : il demande à Orée d'ouvrir la fenêtre de l'application,
/// garde son icône dans le Dock tant qu'elle est ouverte, la ramène au premier plan quand on clique l'icône, et se ferme avec elle.
final class Launcher: NSObject, NSApplicationDelegate {
    private let info = Bundle.main.infoDictionary ?? [:]
    private var id: String { info["OreeAppID"] as? String ?? "" }
    private var bundleID: String { info["OreeBundleID"] as? String ?? "com.nolhan.hyperbrowser" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        openInOree()
        // Orée prévient quand la fenêtre de l'application se ferme, et le raccourci s'en va avec elle.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.nolhan.hyperbrowser.webapp.closed"), object: nil, queue: .main) { [id] note in
            if (note.object as? String) == id || (note.userInfo?["id"] as? String) == id { NSApp.terminate(nil) }
        }
        // Si Orée se ferme, le raccourci aussi.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [bundleID] note in
            if (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == bundleID { NSApp.terminate(nil) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openInOree(); return false }

    private func openInOree() {
        guard let url = URL(string: "oree-app://open/\(id)") else { return }
        let path = info["OreePath"] as? String
        let app = path.flatMap { FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil } ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        guard let app else { NSApp.terminate(nil); return }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, error in
            if error != nil { DispatchQueue.main.async { NSApp.terminate(nil) } }
        }
    }
}

let application = NSApplication.shared
let delegate = Launcher()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
