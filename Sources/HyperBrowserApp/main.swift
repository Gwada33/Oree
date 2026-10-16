import AppKit
import WebKit
import BrowserCore
import BrowserStorage
import BrowserUI

LaunchTrace.mark("main.swift entered")
// First WebContent process starts now, in parallel with building the window.
ProcessPoolFactory.warmUpFirstProcess()

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var browserController: BrowserWindowController?
    /// Windows opened with ⌘N (the first one is `browserController`). Kept here: nothing else owns a window controller.
    private var extraControllers: [BrowserWindowController] = []
    var menuBuilder: MenuBuilder?
    let contentBlocker = ContentBlockerManager()

    /// Links that arrive before the window exists (Orée launched *by* clicking a link elsewhere) or before the session is back.
    private var pendingURLs: [URL] = []
    private var sessionReady = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTrace.mark("didFinishLaunching")
        // Le panneau « correction orthographique » d'une page web (la bulle « Voulez-vous dire… ? ») plante parfois l'application : AppKit lève une
        // exception en l'affichant dans une fenêtre (rapport du 11 octobre, `NSRemoteView containingWindowWillOrderOnScreen:`). On le coupe par défaut ;
        // le soulignement des fautes reste, et un réglage explicite de l'utilisateur (Édition › Orthographe) l'emporte.
        UserDefaults.standard.register(defaults: ["WebAutomaticSpellingCorrectionEnabled": false, "NSAutomaticSpellingCorrectionEnabled": false])
        AppGuards.install()   // exceptions of AppKit's correction panel must not stop the app
        DiagnosticsReporter.shared.start()
        ThemeBootstrap.start()

        // Show the window immediately with no network/compile work blocking the
        // main thread; the ad/tracker block list is wired in as soon as it's
        // ready (compiling it is local and fast, but there's no reason to make
        // every single launch wait on it before the user sees anything).
        let controller = BrowserWindowController(contentBlocker: contentBlocker)
        browserController = controller

        BrowserWindowController.newWindowHandler = { [weak self] withTab in self?.openNewWindow(withTab: withTab) }
        BrowserWindowController.extraWindowsProvider = { [weak self] in self?.extraControllers ?? [] }
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
        controller.window?.displayIfNeeded()   // paint the empty window now; the tabs follow
        LaunchTrace.mark("window shown")

        // The session comes back once the window is already visible. Links that launched us open after it.
        DispatchQueue.main.async { [self] in
            controller.restoreSession(openFreshTab: pendingURLs.isEmpty) { [self] in
                sessionReady = true
                pendingURLs.forEach { controller.openExternal($0) }
                pendingURLs.removeAll()
                controller.ensureTabExists()
                controller.journalStart()
                controller.showOnboardingIfNeeded()
                restoreExtraWindows()
            }
        }

        // After the window is up: applies cached/baseline rules at once, then
        // refreshes the filter lists in the background.
        contentBlocker.start()
        controller.checkForUpdatesInBackground()

        // UI test channel for development only: off unless explicitly requested.
        // Never in a shipped build: the channel can drive the browser and skips the fingerprint check of the password vault.
        #if DEBUG
        if CommandLine.arguments.contains("--automation") { controller.enableAutomation() }
        #endif
    }

    /// Links from other apps (when HyperBrowser is the default browser) and .html files.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard sessionReady, let browserController else { pendingURLs += urls; return }
        for url in urls { browserController.openExternal(url) }
    }

    /// The windows opened with ⌘N in the previous session, brought back next to the first (nothing is saved while they come back).
    private func restoreExtraWindows() {
        let saved = BrowserWindowController.savedExtraWindows()
        guard !saved.isEmpty, ProcessInfo.processInfo.environment["HB_FRESH_SESSION"] != "1" else { return }
        BrowserWindowController.suspendExtraSaves = true
        for tabs in saved { openNewWindow(withTab: false).restoreExtraWindow(tabs) }
        BrowserWindowController.suspendExtraSaves = false
        BrowserWindowController.saveExtraWindows()
    }

    /// ⌘N: another window with its own tabs, next to the first (down and right of the one in front, as every Mac app does).
    @discardableResult
    func openNewWindow(withTab: Bool = true) -> BrowserWindowController {
        let controller = BrowserWindowController(contentBlocker: contentBlocker, isSecondary: true)
        controller.menuBuilder = menuBuilder
        extraControllers.append(controller)
        if let front = NSApp.keyWindow ?? browserController?.window, let window = controller.window {
            window.setFrame(front.frame, display: false)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: front.frame.minX + 28, y: front.frame.maxY - 28)))
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if withTab { controller.ensureTabExists() }
        if let window = controller.window {
            let id = ObjectIdentifier(controller)
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.extraControllers.removeAll { ObjectIdentifier($0) == id }
                    // A window the user closes is gone for good; but not while the app quits (then it must come back).
                    if self?.isQuitting == false { BrowserWindowController.saveExtraWindows() }
                }
            }
        }
        return controller
    }

    private var isQuitting = false
    private var forgetAtQuit = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isQuitting = true
        browserController?.flushSession()
        BrowserWindowController.saveExtraWindows()       // one last time, with every window still open
        let settings = SettingsStore.shared
        guard settings.clearHistoryOnQuit || settings.clearSiteDataOnQuit else { return .terminateNow }
        // The user asked to forget history and/or site data at quit: do it, then quit (and keep no picture of the pages either).
        forgetAtQuit = true
        Task { @MainActor in
            await BrowserWindowController.clearAtQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        browserController?.flushSession()
        BrowserWindowController.endJournalSession()
        if !forgetAtQuit { browserController?.persistSleepSnapshots() }  // encrypted, only for tabs that are still open (see SnapshotVault)
        BrowserWindowController.purgeSnapshots()   // the plain pictures never outlive the app
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
