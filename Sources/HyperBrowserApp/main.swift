import AppKit
import WebKit
import BrowserCore
import BrowserUI

LaunchTrace.mark("main.swift entered")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var browserController: BrowserWindowController?
    var menuBuilder: MenuBuilder?
    let contentBlocker = ContentBlockerManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTrace.mark("didFinishLaunching")
        DiagnosticsReporter.shared.start()
        ThemeBootstrap.start()

        // Show the window immediately with no network/compile work blocking the
        // main thread; the ad/tracker block list is wired in as soon as it's
        // ready (compiling it is local and fast, but there's no reason to make
        // every single launch wait on it before the user sees anything).
        let controller = BrowserWindowController(contentBlocker: contentBlocker)
        browserController = controller

        LaunchTrace.mark("window controller built")
        let builder = MenuBuilder(target: controller)
        controller.menuBuilder = builder
        menuBuilder = builder
        NSApp.mainMenu = builder.build()

        // No forced activation: macOS already brings the app forward when *you* open it
        // (Dock, Finder, Spotlight) and leaves it behind for background launches
        // (`open -g`, scripts). Forcing it stole focus from whatever you were doing.
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        LaunchTrace.mark("window shown")
        controller.showOnboardingIfNeeded()

        // After the window is up: applies cached/baseline rules at once, then
        // refreshes the filter lists in the background.
        contentBlocker.start()
        controller.checkForUpdatesInBackground()

        // UI test channel for development only: off unless explicitly requested.
        if CommandLine.arguments.contains("--automation") { controller.enableAutomation() }
    }

    /// Links from other apps (when HyperBrowser is the default browser) and .html files.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { browserController?.openExternal(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
