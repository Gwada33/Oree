import Testing
import Foundation
@testable import BrowserCore

@Suite struct WebAppTests {
    private let app = WebApp(id: "A1", name: "YouTube", startURL: "https://www.youtube.com/")

    @Test func scopeIsTheSiteAndItsSubdomains() {
        #expect(WebAppScope.contains(URL(string: "https://www.youtube.com/watch?v=1")!, in: app))
        #expect(WebAppScope.contains(URL(string: "https://music.youtube.com/")!, in: app))
        #expect(WebAppScope.contains(URL(string: "https://youtube.com/")!, in: app))
        #expect(!WebAppScope.contains(URL(string: "https://example.com/")!, in: app))
        #expect(!WebAppScope.contains(URL(string: "https://notyoutube.com/")!, in: app))
        #expect(WebAppScope.contains(URL(string: "about:blank")!, in: app))
    }

    @Test func storeKeepsApps() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apps-" + UUID().uuidString, isDirectory: true)
        let store = WebAppStore(directory: dir)
        #expect(store.all().isEmpty)
        try store.add(app); try store.add(WebApp(id: "B2", name: "Agenda", startURL: "https://calendar.google.com/"))
        #expect(store.all().map(\.name) == ["Agenda", "YouTube"])
        #expect(store.app(forHost: "youtube.com")?.id == "A1" && store.app(forHost: "www.youtube.com")?.id == "A1")
        try store.add(WebApp(id: "A1", name: "YT", startURL: app.startURL))      // même identifiant : remplacé
        #expect(store.all().count == 2 && store.app(id: "A1")?.name == "YT")
        try store.remove(id: "A1")
        #expect(store.all().map(\.id) == ["B2"])
    }

    @Test func shortcutNamesAreSafe() {
        #expect(WebAppShortcut.folderName(for: "YouTube") == "YouTube.app")
        #expect(WebAppShortcut.folderName(for: "a/b:c") == "a-b-c.app")
        #expect(WebAppShortcut.folderName(for: "  ") == "Application.app")
        #expect(WebAppShortcut.openURL(for: app).absoluteString == "oree-app://open/A1")
    }

    @Test func infoPlistNamesTheLauncherAndTheApp() throws {
        let data = try WebAppShortcut.infoPlist(for: app, oreePath: "/Applications/Oree.app")
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        #expect(plist["CFBundleExecutable"] as? String == "OreeAppLauncher" && plist["OreeAppID"] as? String == "A1" && plist["CFBundleIdentifier"] as? String == "com.nolhan.hyperbrowser.webapp.a1")
    }
}
