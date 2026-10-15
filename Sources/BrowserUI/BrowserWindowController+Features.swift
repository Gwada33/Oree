import AppKit
import WebKit
import SwiftUI
import BrowserCore
import BrowserStorage
import BrowserSettingsUI
import DownloadKit
import OreeObjC
import MediaPlayer

extension BrowserWindowController {

    // MARK: - Archive of unused tabs

    static let archiveStore = TabArchiveStore(key: "tabArchive.v1" + benchSuffix)
    static let lastActiveKey = "session.lastActive" + benchSuffix

    /// Closes (and remembers) the tabs nobody has touched for the chosen number of days.
    func archiveStaleTabs(now: Date = Date()) {
        let days = SettingsStore.shared.tabArchiveDays
        guard days > 0, !isSecondary else { return }
        let stale = tabs.filter { tab in
            TabArchivePolicy.canArchive(url: tab.currentURL, isPrivate: tab.isPrivate, isActive: tab.id == activeTabID || isOnScreen(tab),
                                        playsAudio: tab.audioState != .none)
                && TabArchivePolicy.isStale(idle: now.timeIntervalSince(tab.lastActiveDate), days: days)
        }
        guard !stale.isEmpty, stale.count < tabs.count else { return }
        var list = Self.archiveStore.load()
        for tab in stale {
            guard let url = tab.currentURL else { continue }
            list = TabArchivePolicy.adding(ArchivedTab(url: url.absoluteString, title: tab.displayTitle, space: tab.spaceIndex, archivedAt: now), to: list)
        }
        Self.archiveStore.save(list)
        for tab in stale { closeTab(tab, remember: false) }
        presentNotice(stale.count == 1 ? "Un onglet inutilisé a été archivé." : "\(stale.count) onglets inutilisés ont été archivés.")
    }

    /// The archive as a menu: a click brings a tab back in its space; the last item empties the list.
    func showArchiveMenu() {
        let list = Self.archiveStore.load()
        let menu = NSMenu()
        if list.isEmpty {
            let empty = NSMenuItem(title: "Aucun onglet archivé", action: nil, keyEquivalent: ""); empty.isEnabled = false
            menu.addItem(empty)
        }
        for entry in list.prefix(40) {
            let host = URL(string: entry.url)?.host ?? entry.url
            let item = ClosureMenuItem(title: entry.title.isEmpty ? host : "\(entry.title) — \(host)") { [weak self] in
                guard let self else { return }
                Self.archiveStore.save(Self.archiveStore.load().filter { $0.url != entry.url })
                self.newTab(urlString: entry.url, isPrivate: false)
                if let tab = self.activeTab { tab.spaceIndex = min(max(entry.space, 0), self.spaces.count - 1) }
            }
            menu.addItem(item)
        }
        if !list.isEmpty {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Vider l’archive") { Self.archiveStore.save([]) })
        }
        let point = window.map { $0.contentView?.convert($0.mouseLocationOutsideOfEventStream, from: nil) ?? .zero } ?? .zero
        menu.popUp(positioning: nil, at: point, in: window?.contentView)
    }

    /// Tabs' last use, saved with the session so that "unused for 7 days" also counts the days the app was closed.
    func saveLastActive() {
        var map: [String: Double] = [:]
        for tab in tabs where !tab.isPrivate { if let url = tab.currentURL?.absoluteString { map[url] = tab.lastActiveDate.timeIntervalSince1970 } }
        UserDefaults.standard.set(map, forKey: Self.lastActiveKey)
    }
    func restoreLastActive(_ tab: Tab, url: String) {
        if let when = (UserDefaults.standard.dictionary(forKey: Self.lastActiveKey) as? [String: Double])?[url] { tab.lastActiveDate = Date(timeIntervalSince1970: when) }
    }

    /// Emergency response: the OS just told us real memory is tight. Discard
    /// background tabs immediately, regardless of how recently they were
    /// used, oldest-touched first, to hand memory back right away rather
    /// than wait for the idle timer. Uses the public `DispatchSource`
    /// memory-pressure API — no private WebKit hooks involved.
    func startMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.lastMemoryPressure = Date()
                // Cheap first: drop WebKit's in-memory caches, then sleep background tabs.
                WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeMemoryCache], modifiedSince: .distantPast) {}
                await self?.suspendAllBackgroundTabs()
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    func suspendAllBackgroundTabs() async {
        let reading = measureTabMemory()
        let tabsPerProcess = Dictionary(grouping: reading.processOfTab.values, by: { $0 }).mapValues(\.count)
        var entries: [TabLifecyclePolicy.Entry] = []
        for tab in tabs where !tab.isSuspended && tab.webView != nil {
            let pid = reading.processOfTab[tab.id]
            let bytes = pid.flatMap { reading.bytesByProcess[$0] } ?? 0
            entries.append(.init(id: tab.id, bytes: bytes / UInt64(max(pid.flatMap { tabsPerProcess[$0] } ?? 1, 1)),
                                 idleSeconds: Date().timeIntervalSince(tab.lastActiveDate),
                                 state: tab.isFrozen ? .frozen : .awake,
                                 exemption: await lifecycleExemption(of: tab)))
        }
        await apply(TabLifecyclePolicy.emergencyPlan(entries: entries), captureGhost: false)   // memory is short: no time for ghosts
    }

    // MARK: - Web panels

    /// The palette's entries for the side panels: one per app, plus adding and removing.
    func webPanelActions() -> [(String, String, @MainActor (BrowserWindowController) -> Void)] {
        var items: [(String, String, @MainActor (BrowserWindowController) -> Void)] = []
        for entry in SettingsStore.shared.webPanels {
            items.append(("Panneau : \(entry.name)", "sidebar.right", { $0.toggleWebPanel(entry) }))
        }
        items.append(("Ajouter un panneau web…", "plus.rectangle.on.rectangle", { $0.addWebPanel() }))
        for entry in SettingsStore.shared.webPanels {
            items.append(("Retirer le panneau « \(entry.name) »", "minus.rectangle", { $0.removeWebPanel(entry) }))
        }
        return items
    }

    func toggleWebPanel(_ entry: WebPanelEntry) {
        if webPanel.isShown, webPanel.current == entry { webPanel.hide() } else { webPanel.show(entry) }
    }

    func removeWebPanel(_ entry: WebPanelEntry) {
        webPanel.remove(entry)
        SettingsStore.shared.webPanels = SettingsStore.shared.webPanels.filter { $0 != entry }
    }

    /// A sheet asking for the address of a web app; the suggestions are one click away.
    func addWebPanel() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Ajouter un panneau web"
        alert.informativeText = "Une application web gardée à droite de la page : saisissez son adresse (par exemple web.whatsapp.com)."
        alert.addButton(withTitle: "Ajouter")
        alert.addButton(withTitle: "Annuler")
        let field = NSComboBox(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        field.placeholderString = "adresse du site"
        field.addItems(withObjectValues: WebPanels.suggestions.map(\.url))
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let text = field.stringValue
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let url = WebPanels.normalize(text) else { self.presentNotice("Cette adresse n’est pas une page web."); return }
                let entry = WebPanelEntry(name: WebPanels.suggestions.first { $0.url == url.absoluteString }?.name ?? WebPanels.defaultName(for: url), url: url.absoluteString)
                SettingsStore.shared.webPanels = WebPanels.adding(entry, to: SettingsStore.shared.webPanels)
                self.webPanel.show(entry)
            }
        }
    }

    /// Shows `url` in the preview card over the page.
    func peek(_ url: URL, from tab: Tab) {
        peekPanel.show(url, configuration: makeConfiguration(isPrivate: tab.isPrivate))
    }

    /// Opens `url` in a small floating window (⌥-click on a link, tab menu, palette).
    func openMiniWindow(url: URL) {
        guard let other = Self.newWindowHandler?(false) else { NSSound.beep(); return }
        other.becomeMini()
        other.newTab(urlString: url.absoluteString, isPrivate: activeTab?.isPrivate ?? false)
        other.shrinkMiniWindow()
    }

    /// WebKit pins the page view to the size it was born with; in a small window that would stretch the window back. Let the window decide.
    func shrinkMiniWindow() {
        guard let web = activeTab?.webView else { return }
        for constraint in web.constraints where constraint.isActive && constraint.secondItem == nil && constraint.constant > 300 { constraint.isActive = false }
        window?.setFrame(miniFrame, display: true)
    }

    var miniFrame: NSRect {
        let area = (NSApp.mainWindow ?? window)?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 420, height: min(640, area.height - 80))
        return NSRect(x: area.maxX - size.width - 24, y: area.minY + 24, width: size.width, height: size.height)
    }

    func becomeMini() {
        isMini = true
        guard let window else { return }
        window.level = .floating
        window.collectionBehavior.insert(.fullScreenNone)
        window.minSize = NSSize(width: 360, height: 320)
        window.setFrame(miniFrame, display: true)
        toggleSidebarButton.symbol = "arrow.up.left.and.arrow.down.right"
        toggleSidebarButton.toolTip = "Ouvrir dans la fenêtre principale"
        toggleSidebarButton.setAccessibilityLabel("Ouvrir dans la fenêtre principale")
        applySidebarMode(animated: false)
        applyChromeLayout()
        window.setFrame(miniFrame, display: true)
    }

    /// The page leaves the mini window for a tab of the main window, and the mini window closes.
    func moveMiniToMainWindow() {
        guard isMini, let url = activeTab?.currentURL,
              let main = NSApp.windows.compactMap({ $0.windowController as? BrowserWindowController }).first(where: { !$0.isSecondary }) else { NSSound.beep(); return }
        main.newTab(urlString: url.absoluteString, isPrivate: activeTab?.isPrivate ?? false)
        main.window?.makeKeyAndOrderFront(nil)
        window?.close()
    }

    /// Takes a tab that another window gave up: it joins this window's current space and becomes the active tab.
    func adopt(_ tab: Tab) {
        tab.spaceIndex = currentSpace
        tab.groupID = nil
        attachTab(tab)
        selectTab(tab)
        saveSession()
    }

    func restoreSessionOrOpenFreshTab(openFreshTab: Bool = true) {
        let snapshots = isFreshSession ? [] : ((try? sessionRepo.load()) ?? [])
        guard snapshots.contains(where: { !$0.url.isEmpty && !$0.isPrivate }) else {
            if openFreshTab { newTab(urlString: nil, isPrivate: SettingsStore.shared.privateByDefault) }
            return
        }

        // Older versions saved private tabs too: never bring those back.
        let restorable = snapshots.filter { !$0.url.isEmpty && !$0.isPrivate }
        let eager = ProcessInfo.processInfo.environment["HB_EAGER_RESTORE"] == "1"   // A/B benchmarking
        let savedActive = UserDefaults.standard.integer(forKey: Self.activeIndexKey)
        let activeIndex = restorable.indices.contains(savedActive) ? savedActive : 0

        for (index, snapshot) in restorable.enumerated() {
            let config = makeConfiguration(isPrivate: snapshot.isPrivate)
            // Only the tab you'll see first is loaded; the rest wait, asleep, until selected.
            if !eager, index != activeIndex, let url = URL(string: snapshot.url) {
                let sleeper = Tab(configuration: config, isPrivate: snapshot.isPrivate, sleeping: (url, snapshot.interactionState, snapshot.title))
                sleeper.spaceIndex = min(max(snapshot.spaceIndex, 0), spaces.count - 1)
                sleeper.groupID = snapshot.groupID.flatMap(UUID.init(uuidString:))
                restoreLastActive(sleeper, url: snapshot.url)
                attachTab(sleeper)
                continue
            }
            let tab = Tab(configuration: config, isPrivate: snapshot.isPrivate)
            tab.spaceIndex = min(max(snapshot.spaceIndex, 0), spaces.count - 1)
            tab.groupID = snapshot.groupID.flatMap(UUID.init(uuidString:))
            attachTab(tab)
            if let state = snapshot.interactionState {
                // Setting `interactionState` alone reconstructs the page,
                // its back-forward list and scroll position — no separate
                // `load()` call needed or wanted here.
                tab.webView?.interactionState = state
            } else {
                load(urlString: snapshot.url, in: tab)
            }
        }
        if tabs.indices.contains(activeIndex) {
            selectTab(tabs[activeIndex])
        } else if let first = tabs.first {
            selectTab(first)
        } else {
            newTab(urlString: nil, isPrivate: SettingsStore.shared.privateByDefault)
        }
        restoreSplit()
        saveSession()   // rewrites the saved session at once: rows left by older versions (private tabs) disappear
    }

    /// Brings back the split screen of the previous session (same two tabs, same ratio).
    func restoreSplit() {
        let saved = UserDefaults.standard.array(forKey: Self.splitKey) as? [Int] ?? []
        guard saved.count == 2, tabs.indices.contains(saved[0]), tabs.indices.contains(saved[1]) else { return }
        let ratio = UserDefaults.standard.double(forKey: Self.splitRatioKey)
        beginSplit(left: tabs[saved[0]], right: tabs[saved[1]])
        if (0.25...0.75).contains(ratio), ratio != 0.5 { setSplitRatio(CGFloat(ratio), animated: false) }
    }

    /// Benchmarks (`HB_DB_PATH` set) use their own key so they never overwrite the real one.
    static let splitKey = ProcessInfo.processInfo.environment["HB_DB_PATH"] == nil ? "session.split" : "session.split.bench"
    static let splitRatioKey = splitKey + ".ratio"
    static let activeIndexKey = ProcessInfo.processInfo.environment["HB_DB_PATH"] == nil ? "session.activeIndex" : "session.activeIndex.bench"

    /// Captures every open (non-private) tab's URL/interaction state and
    /// persists the whole set. Called after every structural change (tab
    /// opened/closed/reordered/navigated) rather than only at quit, so a
    /// crash loses only the last few seconds, not the whole window. Works
    /// for suspended tabs too — `currentURL`/`currentInteractionState` fall
    /// back to what was captured right before suspension.
    func saveSession() {
        // A window opened with ⌘N saves with the others, in its own table; the first window keeps the main session.
        if isSecondary {
            if ProcessInfo.processInfo.environment["HB_FRESH_SESSION"] != "1" { Self.saveExtraWindows() }
            return
        }
        guard !isFreshSession else { return }
        // Tabs with no address (failed load, blank page) aren't worth restoring —
        // they used to come back as empty tabs and pile up on every launch.
        // Private tabs are never written to disk (see SessionPolicy).
        let savable = tabs.filter { SessionPolicy.isSavable(url: $0.currentURL, isPrivate: $0.isPrivate) }
        if let activeTab, let index = savable.firstIndex(where: { $0.id == activeTab.id }) {
            UserDefaults.standard.set(index, forKey: Self.activeIndexKey)
        }
        UserDefaults.standard.set(currentSpace, forKey: Self.activeSpaceKey)
        saveLastActive()
        if let pair = splitPair,
           let l = savable.firstIndex(where: { $0.id == pair.left }), let r = savable.firstIndex(where: { $0.id == pair.right }) {
            UserDefaults.standard.set([l, r], forKey: Self.splitKey)
            UserDefaults.standard.set(Double(splitRatio), forKey: Self.splitRatioKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.splitKey)
        }
        let snapshots = savable.enumerated().map { index, tab in
            TabSnapshot(
                orderIndex: index,
                url: tab.currentURL?.absoluteString ?? "",
                isPrivate: tab.isPrivate,
                interactionState: tab.currentInteractionState,
                title: tab.displayTitle,
                spaceIndex: tab.spaceIndex,
                groupID: tab.groupID?.uuidString
            )
        }
        do {
            try sessionRepo.save(snapshots)
            try groupRepo.save(groups)
        } catch {
            Log.storage.error("Failed to save session: \(error.localizedDescription)")
        }
    }
}
