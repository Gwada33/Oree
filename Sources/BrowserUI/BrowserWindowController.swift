import AppKit
import WebKit
import SwiftUI
import BrowserCore
import BrowserStorage
import BrowserSettingsUI
import DownloadKit

public final class BrowserWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {

    public weak var menuBuilder: MenuBuilder?
    private var settingsWindow: NSWindow?

    private let contentBlocker: ContentBlockerManager
    private nonisolated(unsafe) var settingsObserver: NSObjectProtocol?
    private let processPool = ProcessPoolFactory.launchPool
    private let privateProcessPool = ProcessPoolFactory.makeLeanProcessPool()
    private var tabs: [Tab] = []
    private var activeTabID: UUID?
    // `nonisolated(unsafe)`: only touched from `deinit`, which (unlike the
    // rest of this @MainActor-inferred class) is never actor-isolated in
    // Swift 6 — invalidating a Timer / canceling a dispatch source is
    // documented thread-safe, so there's no real data race here.
    private nonisolated(unsafe) var suspensionTimer: Timer?
    private nonisolated(unsafe) var memoryPressureSource: DispatchSourceMemoryPressure?

    private let historyRepo = HistoryRepository()
    private let bookmarkRepo = BookmarkRepository()
    private let sessionRepo = SessionRepository()
    private let groupRepo = TabGroupRepository()
    private let oreeSchemeHandler = OreeSchemeHandler()
    /// Tab groups of every space, in display order.
    private lazy var groups: [TabGroup] = (try? groupRepo.load()) ?? []
    private let permissionRepo = SitePermissionRepository()
    private let vault = CredentialVault()
    private let credentialHandler = CredentialMessageHandler()
    /// (origin, username) pairs the user said "not now" to, until quit.
    private var declinedSaves: Set<String> = []
    private var credentialPromptInFlight = false

    // Security / privacy state (Phase 3)
    private let fingerprintSeed = UInt32.random(in: .min ... .max)
    private lazy var urlCleaner = URLCleaner.bundled   // compiling its regexes cost ~10 ms of every start
    /// Hosts the user chose to open over plain HTTP, until the app quits.
    private var httpExemptHosts: Set<String> = []
    /// Hosts whose Safe Browsing warning the user chose to ignore, until quit.
    private var safeBrowsingBypass: Set<String> = []
    private var safeBrowsing: SafeBrowsingClient?
    private var safeBrowsingKey = ""
    private var safeBrowsingUpdateTask: Task<Void, Never>?
    private var lastFingerprintSetting: Bool?
    private var lastLongPagesSetting: Bool?

    private let tabBarStack = NSStackView()
    private let pinnedStack = NSStackView()
    private let newTabButton = NSButton()
    private let contentContainer = SurfaceView(fill: Theme.page)

    private let extensionManager = ExtensionManager()
    private let extensionBar = NSStackView()
    private var extensionButtons: [String: ExtensionButton] = [:]
    private let loadingBar = LoadingBarView()
    private let addressPill = AddressPillView()
    private let spaceRail = SpaceRailView()
    private let spaceNameLabel = NSTextField(labelWithString: "")
    private let spaceMetaLabel = NSTextField(labelWithString: "")
    private var toolbar: ToolbarView!
    private var tabColumn: NSView?
    private var railWidth: NSLayoutConstraint?
    /// Full-window panels (customize, welcome, spaces overview, palette) are built the first time they are needed,
    /// not at launch: they are invisible until then, and building them cost ~50 ms of every start.
    private var drawerLoaded = false
    private lazy var drawer: CustomizeDrawerView = {
        drawerLoaded = true
        let view = CustomizeDrawerView()
        installOverlay(view)
        view.onClose = { [weak self] in self?.closeCustomize() }
        view.onChange = { [weak self] in self?.applyLookChanges() }
        view.onPickPhoto = { [weak self] in self?.pickHomePhoto() }
        return view
    }()
    private let sidePanel = SidePanelView()
    private let readingRepo = ReadingListRepository()
    private var panelButtons: [(kind: PanelKind, button: ChromeIconButton)] = []
    private var activePanel: PanelKind?
    private var panelScroll: NSScrollView?
    private let sleepMetaLabel = NSTextField(labelWithString: "")
    enum PanelKind { case favorites, history, downloads, reading }
    private let tabStrip = TabStripView()
    private var stripHeight: NSLayoutConstraint?
    private let addressDropdown = AddressDropdownView()
    private let downloads = DownloadsController()
    private var downloadsPanel: DownloadsPanelView?
    private let downloadsButton = ChromeIconButton(symbol: "arrow.down.to.line", label: "Téléchargements")
    private var downloadsPopover: NSPopover?
    // Split screen: two tabs side by side (not restored at launch).
    private var splitPair: (left: UUID, right: UUID)?
    private var splitRatio: CGFloat = 0.5
    private var splitHeaders: [UUID: SplitPaneHeader] = [:]
    private var splitHinge: SplitHingeView?
    private var splitConstraints: [NSLayoutConstraint] = []
    private var splitLeftWidth: NSLayoutConstraint?
    private var splitMonitor: Any?
    private let splitButton = ChromeIconButton(symbol: "rectangle.split.2x1", label: "Écran partagé  ⌘\\")
    private lazy var overview: SpacesOverviewView = {
        let view = SpacesOverviewView()
        installOverlay(view)
        view.provider = { [weak self] in self?.overviewCards() ?? [] }
        view.onClose = { [weak self] in self?.closeOverview() }
        view.onSelect = { [weak self] index in self?.closeOverview(); self?.selectSpace(index) }
        view.onUpdate = { [weak self] index, name, hue, icon in
            guard let self, self.spaces.indices.contains(index) else { return }
            self.spaces[index].name = name; self.spaces[index].hue = hue; self.spaces[index].icon = icon
            self.refreshSpaceUI(animated: false)
        }
        view.onDelete = { [weak self] in self?.deleteSpace($0) }
        view.onAdd = { [weak self] in self?.addSpace(select: false) }
        return view
    }()
    private lazy var onboarding: OnboardingView = {
        let view = OnboardingView()
        installOverlay(view)
        view.onChange = { [weak self] in self?.applyLookChanges() }
        view.onFinish = { [weak self] in
            self?.applyLookChanges()
            if let webView = self?.activeTab?.webView { self?.window?.makeFirstResponder(webView) }
        }
        view.onImport = { [weak self] browser in
            guard let self else { return 0 }
            let imported = BrowserImporter.importBookmarks(from: browser)
            for item in imported { try? self.bookmarkRepo.add(url: item.url, title: item.title) }
            self.refreshPinnedIcons()
            self.menuBuilder?.refreshBookmarksMenu()
            return imported.count
        }
        return view
    }()
    private var searchRow: SidebarRowView?
    private var newTabRow: SidebarRowView?
    private let collapseButton = ChromeIconButton(symbol: "sidebar.left", label: "Réduire la barre latérale")
    private var paletteLoaded = false
    private lazy var palette: CommandPaletteView = {
        paletteLoaded = true
        let view = CommandPaletteView()
        installOverlay(view)
        view.provider = { [weak self] query, filter in self?.paletteSections(query: query, filter: filter) ?? [] }
        view.onDismiss = { [weak self] in self?.closePalette() }
        return view
    }()

    /// Pins a full-window panel over everything else.
    private func installOverlay(_ view: NSView) {
        guard let content = window?.contentView else { return }
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: content.topAnchor), view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor), view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }
    private let favoritesStack = NSStackView()
    private let backButton = ChromeIconButton(symbol: "chevron.left", label: "Page précédente  ⌘[")
    private let forwardButton = ChromeIconButton(symbol: "chevron.right", label: "Page suivante  ⌘]")
    private let reloadButton = ChromeIconButton(symbol: "arrow.clockwise", label: "Recharger  ⌘R")
    private let toggleSidebarButton = ChromeIconButton(symbol: "sidebar.left", label: "Afficher la barre latérale  ⌥⌘S")
    private let customizeButton = ChromeIconButton(symbol: "paintbrush", label: "Personnaliser  ⌘,")
    private let moreButton = ChromeIconButton(symbol: "ellipsis", label: "Palette de commandes  ⌘K")
    private var sidebarView: NSView?
    private var sidebarWidth: NSLayoutConstraint?
    private var sidebarLeading: NSLayoutConstraint?
    /// Height of the title row (traffic lights + toolbar) at the top of the sidebar.
    private var topRow: CGFloat { isFullScreen ? 44 : CGFloat(OreeTokens.Metrics.toolbarHeight) }
    private var resizeHandleTop: NSLayoutConstraint?
    private var columnTop: NSLayoutConstraint?
    private var isFullScreen = false
    private let titleToolbar: NSToolbar = { let t = NSToolbar(identifier: "oree.titlebar"); t.showsBaselineSeparator = false; return t }()
    private var sidebarTop: NSLayoutConstraint?
    private var sidebarBottom: NSLayoutConstraint?
    private let sidebarGlassView: NSView = SidebarGlass.makeBackground()
    private let resizeHandle = SidebarResizeHandle()
    private let hoverSpaceRow = NSStackView()
    private var mainLeading: NSLayoutConstraint?
    private let mainGuide = NSLayoutGuide()
    private let edgeTrigger = EdgeTriggerView()
    private var floatingShown = false
    // Hover-sidebar behavior: show after a short intent delay, hide shortly after the pointer leaves it —
    // unless a menu is open, the edge is being dragged, or the pointer came back.
    private var floatingShowWork: DispatchWorkItem?
    private var floatingHideWork: DispatchWorkItem?
    private var floatingClickMonitor: Any?
    private var floatingMenuTracking = false
    private var isResizingSidebar = false
    private static let sidebarExpandedWidth = CGFloat(OreeTokens.Metrics.sidebarWidth)

    private let findBar = NSStackView()
    private let findField = NSTextField()
    private var findBarContainer: NSView?

    private var activeTab: Tab? {
        tabs.first { $0.id == activeTabID }
    }

    public init(contentBlocker: ContentBlockerManager) {
        self.contentBlocker = contentBlocker

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Orée"
        window.center()
        window.minSize = NSSize(width: 480, height: 320)

        super.init(window: window)

        try? permissionRepo.purgeSessionScoped()
        currentSpace = isFreshSession ? 0 : min(max(UserDefaults.standard.integer(forKey: Self.activeSpaceKey), 0), spaces.count - 1)
        credentialHandler.onMessage = { [weak self] webView, origin, body in
            self?.handleCredentialMessage(webView: webView, origin: origin, body: body)
        }
        LaunchTrace.mark("controller init: super.init done")
        extensionManager.windowController = self
        extensionManager.onChange = { [weak self] in self?.refreshExtensionToolbar() }
        buildUI()
        LaunchTrace.mark("UI built")
        startSuspensionTimer()
        startAudioTimer()
        startMemoryBudgetTimer()
        refreshSpaceUI(animated: false)
        startMemoryPressureMonitor()
        contentBlocker.onRuleListsChanged = { [weak self] _ in self?.applyRuleLists() }
        // Settings write straight to UserDefaults; re-evaluate whatever
        // depends on them (e.g. the ad-block toggle) as soon as one changes.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyRuleLists()
                self?.settingsChanged()
            }
        }
        refreshSafeBrowsing()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Brings the previous session back (or opens a first tab). Called once the window is already on screen, so
    /// the window appears first and its tabs follow. Extensions load before the first pages, or their content
    /// scripts would miss them.
    /// - Parameter openFreshTab: false when links are about to be opened anyway (Orée launched *by* a link).
    public func restoreSession(openFreshTab: Bool = true, completion: @escaping @MainActor () -> Void) {
        let restore: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.restoreSessionOrOpenFreshTab(openFreshTab: openFreshTab)
            LaunchTrace.mark("session restored")
            completion()
        }
        if extensionManager.hasEnabledExtensions {
            Task { @MainActor [weak self] in
                await self?.extensionManager.loadAll()
                restore()
            }
        } else {
            restore()
        }
    }

    /// A window must never stay empty (e.g. a launch link that could not be opened).
    public func ensureTabExists() {
        if tabs.isEmpty { newTab(urlString: nil, isPrivate: SettingsStore.shared.privateByDefault) }
    }

    private var automation: AutomationServer?
    private var lastMemoryPressure: Date?
    private var firstCommitTraced = false
    /// Recently closed tabs, newest last (⌘⇧T reopens the last one).
    private var closedTabs: [(url: URL, state: Data?, title: String?, space: Int)] = []

    // Spaces: Perso / Travail / Lecture. Same cookies and logins everywhere (they only
    // group tabs); each tab belongs to exactly one, and only one space is visible.
    private var currentSpace = 0
    private var lastActiveTabInSpace: [Int: UUID] = [:]
    private nonisolated(unsafe) var audioTimer: Timer?
    private nonisolated(unsafe) var memoryBudgetTimer: Timer?
    private var lastGarbageCollection = Date.distantPast
    private let siteMemoryRepo = SiteMemoryRepository()
    private var siteProfileCache: [String: SiteProfile?] = [:]
    private static let benchSuffix = ProcessInfo.processInfo.environment["HB_DB_PATH"] == nil ? "" : ".bench"
    private static let spaceNamesKey = "spaces.names" + benchSuffix
    private static let spaceStylesKey = "spaces.styles" + benchSuffix
    private static let activeSpaceKey = "session.activeSpace" + benchSuffix

    /// The user's spaces (name, hue, icon). Migrates the older names-only list on first read.
    private lazy var spaces: [SpaceStyle] = {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.spaceStylesKey),
           let saved = try? JSONDecoder().decode([SpaceStyle].self, from: data), !saved.isEmpty {
            return saved
        }
        var initial = SpaceStyle.defaults
        let oldNames = defaults.stringArray(forKey: Self.spaceNamesKey) ?? []
        if oldNames.count == initial.count { for i in initial.indices { initial[i].name = oldNames[i] } }
        return initial
    }() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(spaces), forKey: Self.spaceStylesKey) }
    }
    private var currentSpaceStyle: SpaceStyle { spaces[min(currentSpace, spaces.count - 1)] }

    /// Debug UI-testing channel; the app only calls this for `--automation`.
    public func enableAutomation() {
        guard let window else { return }
        VaultUnlocker.automationBypass = true   // no fingerprint sensor in scripted tests
        defer {
            automation?.extensionOperation = { [weak self] op in
                guard let manager = self?.extensionManager else { return "no manager" }
                let parts = op.split(separator: ":").map(String.init)
                guard parts.count == 2, let item = manager.installedExtensions().first else { return "no extension" }
                switch parts[0] {
                case "disable": manager.setEnabled(false, id: item.id)
                case "enable": manager.setEnabled(true, id: item.id)
                case "remove": manager.remove(id: item.id)
                default: return "unknown op"
                }
                return "\(parts[0]) done; installed now: \(manager.installedExtensions().map { "\($0.name)(enabled=\($0.isEnabled))" })"
            }
        }
        automation = AutomationServer(
            window: window,
            activeWebView: { [weak self] in self?.activeTab?.webView },
            overlays: { [weak self] in [self?.activeTab?.interstitial, self?.loadingBar, (self?.paletteLoaded == true ? self?.palette : nil), self?.addressDropdown, (self?.floatingShown == true ? self?.sidebarView : nil), self?.demoPanel, self?.drawer, self?.overview, self?.onboarding, self?.findBarContainer].compactMap { $0 } },
            installExtension: { [weak self] url in
                guard let manager = self?.extensionManager else { throw CancellationError() }
                manager.autoApprove = true   // the channel can't click the permission sheet
                try await manager.install(from: url)
            },
            extensionsReport: { [weak self] in self?.extensionManager.report() ?? "-" },
            perform: { [weak self] selector in
                guard let self else { return false }
                if self.responds(to: selector) { _ = self.perform(selector); return true }
                if let window = self.window, window.responds(to: selector) { _ = window.perform(selector, with: nil); return true }
                return false
            }
        )
    }

    deinit {
        suspensionTimer?.invalidate()
        audioTimer?.invalidate()
        memoryBudgetTimer?.invalidate()
        memoryPressureSource?.cancel()
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    /// Pushes the current rule lists (or none, if ad blocking is switched off)
    /// to every tab. Safe to call repeatedly — it just replaces what's there.
    private func applyRuleLists() {
        let lists = SettingsStore.shared.adBlockEnabled ? contentBlocker.ruleLists : []
        for tab in tabs { tab.applyContentRuleLists(lists) }
    }

    // MARK: - Security & privacy (Phase 3)

    /// Scripts injected into a page: fingerprint protection (all pages) and,
    /// when ad blocking is on, the cosmetic CSS matching this URL.
    private func userScripts(for url: URL?) -> [WKUserScript] {
        var scripts: [WKUserScript] = [CredentialScript.makeUserScript()]
        let exempt = ProtectionPolicy.isExempt(host: url?.host, list: SettingsStore.shared.protectionExemptHosts)
        if SettingsStore.shared.lightLongPages { scripts.append(LongPageScript.makeUserScript()) }
        if SettingsStore.shared.fingerprintProtection, !exempt {
            scripts.append(FingerprintProtection.makeUserScript(sessionSeed: fingerprintSeed))
        }
        if SettingsStore.shared.adBlockEnabled, !exempt, let url, url.scheme == "http" || url.scheme == "https" {
            let css = contentBlocker.cosmetic.css(for: url)
            if !css.isEmpty, let script = CosmeticScript.makeUserScript(css: css) { scripts.append(script) }
        }
        return scripts
    }

    /// Reacts to settings that need more than a re-read: the fingerprint
    /// toggle (scripts are baked into each tab) and Safe Browsing on/off/key.
    private var lastShortcutOverrides = SettingsStore.shared.shortcutOverrides
    private var lastLook = LookProfile.capture(named: "", from: SettingsStore.shared)
    private var lastSidebarPrefs = [SettingsStore.shared.sidebarWidth, SettingsStore.shared.sidebarGlass ? 1 : 0]

    private func settingsChanged() {
        // Look settings edited elsewhere (Réglages, a configuration) apply live.
        let look = LookProfile.capture(named: "", from: SettingsStore.shared)
        let sidebarPrefs = [SettingsStore.shared.sidebarWidth, SettingsStore.shared.sidebarGlass ? 1 : 0]
        if look != lastLook || sidebarPrefs != lastSidebarPrefs { if drawerLoaded { drawer.refreshFromSettings() }; applyLookChanges() }
        if SettingsStore.shared.shortcutOverrides != lastShortcutOverrides {
            lastShortcutOverrides = SettingsStore.shared.shortcutOverrides
            menuBuilder?.rebuild()
        }
        let fingerprint = SettingsStore.shared.fingerprintProtection
        let longPages = SettingsStore.shared.lightLongPages
        if lastFingerprintSetting != fingerprint || lastLongPagesSetting != longPages {
            lastFingerprintSetting = fingerprint
            lastLongPagesSetting = longPages
            for tab in tabs { tab.setUserScripts(userScripts(for: tab.currentURL)) }
        }
        refreshSafeBrowsing()
        let inspectable = SettingsStore.shared.webInspectorEnabled
        for tab in tabs { tab.setInspectable(inspectable) }
    }

    /// Creates (or drops) the Safe Browsing client to match the settings.
    /// Opt-in: with the setting off, no list is downloaded and no URL data leaves the machine.
    private func refreshSafeBrowsing() {
        let settings = SettingsStore.shared
        let key = settings.safeBrowsingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.safeBrowsingEnabled, !key.isEmpty else {
            safeBrowsing = nil; safeBrowsingKey = ""
            safeBrowsingUpdateTask?.cancel(); safeBrowsingUpdateTask = nil
            return
        }
        guard key != safeBrowsingKey || safeBrowsing == nil else { return }
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HyperBrowser/SafeBrowsing", isDirectory: true)
        let client = SafeBrowsingClient(transport: URLSessionSafeBrowsingTransport(apiKey: key), directory: directory)
        safeBrowsing = client
        safeBrowsingKey = key
        safeBrowsingUpdateTask?.cancel()
        safeBrowsingUpdateTask = Task {
            // The client itself enforces the server's minimum wait / backoff.
            while !Task.isCancelled {
                await client.updateLists()
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
    }

    private func permissionOrigin(_ origin: WKSecurityOrigin) -> String {
        origin.port > 0 ? "\(origin.protocol)://\(origin.host):\(origin.port)" : "\(origin.protocol)://\(origin.host)"
    }

    /// Decides camera/mic/location access: a remembered choice wins, otherwise
    /// ask. Private tabs neither read nor write the permission store.
    private func decidePermission(_ kinds: [SitePermission], origin: WKSecurityOrigin, webView: WKWebView) async -> WKPermissionDecision {
        let isPrivate = tab(for: webView)?.isPrivate ?? false
        let key = permissionOrigin(origin)
        if !isPrivate {
            let stored = kinds.map { try? permissionRepo.decision(origin: key, permission: $0) }
            if stored.contains(where: { $0?.decision == .deny }) { return .deny }
            if stored.allSatisfy({ $0?.decision == .allow }) { return .grant }
        }
        let names = kinds.map { kind -> String in
            switch kind {
            case .camera: return "la caméra"
            case .microphone: return "le micro"
            case .location: return "votre position"
            }
        }.joined(separator: " et ")
        let alert = NSAlert()
        alert.messageText = "« \(origin.host) » souhaite utiliser \(names)"
        alert.informativeText = isPrivate
            ? "Cette autorisation ne sera pas mémorisée (onglet privé)."
            : "Par défaut, ce choix est oublié à la fermeture de HyperBrowser."
        alert.addButton(withTitle: "Autoriser")
        alert.addButton(withTitle: "Refuser")
        if !isPrivate { alert.addButton(withTitle: "Toujours autoriser") }

        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            if let window {
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else {
                continuation.resume(returning: alert.runModal())
            }
        }
        let allow = response == .alertFirstButtonReturn || response == .alertThirdButtonReturn
        let scope: PermissionScope = response == .alertThirdButtonReturn ? .permanent : .session
        if !isPrivate {
            for kind in kinds {
                try? permissionRepo.set(origin: key, permission: kind, decision: allow ? .allow : .deny, scope: scope)
            }
        }
        return allow ? .grant : .deny
    }

    private func showUnsafeSiteWarning(_ threat: ThreatKind, url: URL, in tab: Tab) {
        let host = url.host ?? url.absoluteString
        tab.interstitial.show(.unsafeSite(
            host: host,
            threatDescription: threat.userDescription,
            goBack: { [weak tab] in
                guard let tab else { return }
                tab.interstitial.hide()
                if tab.webView?.canGoBack == true { tab.webView?.goBack() }
            },
            proceed: { [weak self, weak tab] in
                guard let self, let tab else { return }
                self.safeBrowsingBypass.insert(host.lowercased())
                tab.interstitial.hide()
                tab.webView?.load(URLRequest(url: url))
            }
        ))
    }

    // MARK: - Flat floating-card helpers

    /// Wraps `inner` in an opaque white, rounded, drop-shadowed card — the
    /// "floating panel" look used throughout this UI. Two layers are needed
    /// because a single layer can't both clip its content to rounded corners
    /// (`masksToBounds`) and cast a shadow outside those same bounds.
    private func makeFloatingCard(_ inner: NSView, cornerRadius: CGFloat) -> NSView {
        inner.translatesAutoresizingMaskIntoConstraints = false

        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.backgroundColor = Theme.card.cgColor
        clip.layer?.cornerRadius = cornerRadius
        // HB_NO_CARD_MASK / HB_NO_CARD_SHADOW: A/B switches for measuring what the card chrome costs.
        clip.layer?.masksToBounds = ProcessInfo.processInfo.environment["HB_NO_CARD_MASK"] == nil
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: clip.topAnchor),
            inner.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
        ])

        let shadowHost = NSView()
        shadowHost.wantsLayer = true
        shadowHost.layer?.shadowColor = NSColor.black.cgColor
        shadowHost.layer?.shadowOpacity = ProcessInfo.processInfo.environment["HB_NO_CARD_SHADOW"] == nil ? 0.10 : 0
        shadowHost.layer?.shadowRadius = 14
        shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -3)
        shadowHost.translatesAutoresizingMaskIntoConstraints = false
        shadowHost.addSubview(clip)
        NSLayoutConstraint.activate([
            clip.topAnchor.constraint(equalTo: shadowHost.topAnchor),
            clip.bottomAnchor.constraint(equalTo: shadowHost.bottomAnchor),
            clip.leadingAnchor.constraint(equalTo: shadowHost.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: shadowHost.trailingAnchor),
        ])
        return shadowHost
    }

    // MARK: - UI construction

    /// Window → [sidebar: rail + tab column] | [toolbar over (lisière + page sheet)].
    private func buildUI() {
        guard let window else { return }

        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 640, height: 480)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        // An empty unified toolbar makes macOS itself center the traffic lights in a 52 pt title row,
        // so they line up with our toolbar (no frame hacks that macOS would undo on the next layout).
        window.toolbar = titleToolbar
        window.toolbarStyle = .unified

        let root = SurfaceView(fill: Theme.chrome)
        root.translatesAutoresizingMaskIntoConstraints = true
        window.contentView = root
        let contentView: NSView = root

        let sidebar = buildSidebar()
        sidebarView = sidebar
        (sidebar as? SurfaceView)?.onHover = { [weak self] inside in
            if inside { self?.floatingHideWork?.cancel() } else { self?.scheduleFloatingHide(after: 0.35) }
        }
        let resizeHandleTop = resizeHandle.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: topRow)
        self.resizeHandleTop = resizeHandleTop
        // Liquid Glass backdrop (behind everything) and the drag handle on the right edge.
        sidebarGlassView.translatesAutoresizingMaskIntoConstraints = false
        sidebarGlassView.isHidden = true
        sidebar.addSubview(sidebarGlassView, positioned: .below, relativeTo: nil)
        sidebar.addSubview(resizeHandle)
        NSLayoutConstraint.activate([
            sidebarGlassView.topAnchor.constraint(equalTo: sidebar.topAnchor), sidebarGlassView.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            sidebarGlassView.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor), sidebarGlassView.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            resizeHandleTop, resizeHandle.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            resizeHandle.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor), resizeHandle.widthAnchor.constraint(equalToConstant: 8),
        ])
        resizeHandle.onDrag = { [weak self] x in self?.isResizingSidebar = true; self?.resizeSidebar(toRight: x, final: false) }
        resizeHandle.onEnd = { [weak self] x in self?.resizeSidebar(toRight: x, final: true); self?.isResizingSidebar = false; self?.scheduleFloatingHide(after: 0.6) }
        resizeHandle.onReset = { [weak self] in
            SettingsStore.shared.sidebarWidth = SidebarWidth.standard
            self?.applySidebarMode(animated: true)
        }

        // Toolbar: ← → ↻ · address · customize, more.
        for (button, action) in [(backButton, #selector(goBack)), (forwardButton, #selector(goForward)),
                                 (reloadButton, #selector(reloadAction))] as [(ChromeIconButton, Selector)] {
            button.onClick = { [weak self] in _ = self?.perform(action) }
        }
        toggleSidebarButton.onClick = { [weak self] in self?.toggleSidebar() }
        customizeButton.onClick = { [weak self] in self?.openCustomize() }
        moreButton.onClick = { [weak self] in self?.openPalette(initialText: "", selectAll: false, opensInNewTab: true) }
        addressPill.onClick = { [weak self] in self?.focusAddressBar() }
        let bar = ToolbarView(pill: addressPill)
        toolbar = bar
        [toggleSidebarButton, backButton, forwardButton, reloadButton].forEach(bar.leftStack.addArrangedSubview)
        splitButton.onClick = { [weak self] in self?.toggleSplit() }
        downloadsButton.isHidden = true
        downloadsButton.onClick = { [weak self] in self?.toggleDownloads() }
        downloads.onChange = { [weak self] in self?.downloadsChanged() }
        downloads.onFinish = { [weak self] in self?.downloadsButton.pulse() }
        downloads.onStart = { [weak self] in
            guard let self else { return }
            self.downloadsButton.pulse()
            // Show the list (once, if it isn't open yet) so the user sees the download begin.
            if self.downloadsPopover?.isShown != true { self.toggleDownloads() }
        }
        downloads.resumeWebView = { [weak self] in self?.activeTab?.webView }
        downloads.start()
        [splitButton, customizeButton, downloadsButton, moreButton].forEach(bar.rightStack.addArrangedSubview)

        // Page sheet: top-left corner rounded, flush against the right and bottom edges.
        contentContainer.cornerRadius = Theme.pageCornerRadius
        contentContainer.maskedCorners = [.layerMinXMaxYCorner]
        contentContainer.clips = true
        contentContainer.addSubview(loadingBar)
        NSLayoutConstraint.activate([
            loadingBar.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            loadingBar.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            loadingBar.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            loadingBar.heightAnchor.constraint(equalToConstant: 2),
        ])

        // The sidebar goes last so, in floating mode, it overlays the page.
        [tabStrip, bar, contentContainer, sidebar].forEach(contentView.addSubview)
        contentView.addLayoutGuide(mainGuide)
        let mainLead = mainGuide.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: expandedSidebarWidth)
        mainLeading = mainLead
        let sideLead = sidebar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        let sidebarTopConstraint = sidebar.topAnchor.constraint(equalTo: contentView.topAnchor)
        let sidebarBottomConstraint = sidebar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        sidebarTop = sidebarTopConstraint
        sidebarBottom = sidebarBottomConstraint
        sidebarLeading = sideLead

        let width = sidebar.widthAnchor.constraint(equalToConstant: expandedSidebarWidth)
        sidebarWidth = width
        let stripH = tabStrip.heightAnchor.constraint(equalToConstant: 0)
        stripHeight = stripH
        stripH.isActive = true
        tabStrip.spaceChip.onClick = { [weak self] in self?.openOverview() }
        tabStrip.newTabButton.onClick = { [weak self] in self?.newTabAction() }
        NSLayoutConstraint.activate([
            sidebarTopConstraint, sidebarBottomConstraint,
            sideLead, mainLead,
            mainGuide.widthAnchor.constraint(equalToConstant: 0),
            width,

            tabStrip.topAnchor.constraint(equalTo: contentView.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bar.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: mainGuide.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            contentContainer.topAnchor.constraint(equalTo: bar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: mainGuide.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        contentView.addSubview(addressDropdown)
        NSLayoutConstraint.activate([
            addressDropdown.topAnchor.constraint(equalTo: addressPill.bottomAnchor, constant: 6),
            addressDropdown.leadingAnchor.constraint(equalTo: addressPill.leadingAnchor),
            addressDropdown.trailingAnchor.constraint(equalTo: addressPill.trailingAnchor),
        ])
        addressPill.onTextChange = { [weak self] text in self?.refreshAddressSuggestions(text) }
        addressPill.onMove = { [weak self] delta in self?.addressDropdown.move(delta) }
        addressPill.onEndEditing = { [weak self] in self?.endAddressEditing() }
        addressPill.onCommit = { [weak self] text, newTab in self?.commitAddress(text, newTab: newTab) }
        addressDropdown.onPick = { [weak self] item in
            self?.endAddressEditing()
            item.perform(false)
        }

        contentView.addSubview(edgeTrigger)
        edgeTrigger.onReveal = { [weak self] in self?.scheduleFloatingShow() }
        edgeTrigger.onLeave = { [weak self] in self?.floatingShowWork?.cancel() }
        let center = NotificationCenter.default
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.floatingMenuTracking = true; self?.floatingHideWork?.cancel() }
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.floatingMenuTracking = false; self?.scheduleFloatingHide(after: 0.8) }
        }
        NSLayoutConstraint.activate([
            edgeTrigger.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            edgeTrigger.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 60),
            edgeTrigger.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            edgeTrigger.widthAnchor.constraint(equalToConstant: 10),
        ])

        buildFindBar(in: contentView)

        applySidebarMode(animated: false)
    }

    /// Left dock: a 44 pt row for the traffic lights, then the space rail and the tab column
    /// (space name, search, new tab, favorites, tabs — one scroll so long lists scroll in place).
    private func buildSidebar() -> NSView {
        let sidebar = SurfaceView()
        sidebar.setAccessibilityElement(true)
        sidebar.setAccessibilityRole(.group)
        sidebar.setAccessibilityLabel("Barre latérale")

        spaceRail.onSelect = { [weak self] in self?.selectSpace($0) }
        spaceRail.onRename = { [weak self] in self?.renameSpace($0) }
        spaceRail.onNewSpace = { [weak self] in self?.addSpace() }
        spaceRail.onOverview = { [weak self] in self?.openOverview() }
        spaceRail.onSettings = { [weak self] in self?.openSettings() }
        collapseButton.onClick = { [weak self] in self?.toggleCompactSidebar() }

        let column = SurfaceView()
        let columnTopConstraint = column.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: topRow)
        columnTop = columnTopConstraint
        spaceNameLabel.font = Theme.Typo.subheading
        spaceNameLabel.textColor = Theme.text
        spaceMetaLabel.font = Theme.sans(12)
        spaceMetaLabel.textColor = Theme.muted
        hoverSpaceRow.orientation = .horizontal
        hoverSpaceRow.spacing = 4
        hoverSpaceRow.alignment = .centerY
        hoverSpaceRow.translatesAutoresizingMaskIntoConstraints = false
        hoverSpaceRow.isHidden = true
        let header = NSStackView(views: [spaceNameLabel, spaceMetaLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2
        header.translatesAutoresizingMaskIntoConstraints = false
        let topStack = NSStackView(views: [hoverSpaceRow, header])
        topStack.orientation = .vertical
        topStack.alignment = .leading
        topStack.spacing = 8
        topStack.translatesAutoresizingMaskIntoConstraints = false

        let searchRow = SidebarRowView(symbol: "magnifyingglass", title: "Rechercher, aller à…", shortcut: "⌘K")
        searchRow.onClick = { [weak self] in self?.openPalette(initialText: "", selectAll: false, opensInNewTab: true) }
        let newTabRow = SidebarRowView(symbol: "plus", title: "Nouvel onglet", shortcut: "⌘T")
        newTabRow.onClick = { [weak self] in self?.newTabAction() }
        self.searchRow = searchRow
        self.newTabRow = newTabRow

        favoritesStack.orientation = .vertical
        favoritesStack.spacing = 6
        favoritesStack.alignment = .leading
        favoritesStack.translatesAutoresizingMaskIntoConstraints = false

        tabBarStack.orientation = .vertical
        tabBarStack.spacing = 2
        tabBarStack.distribution = .fill
        tabBarStack.alignment = .width
        tabBarStack.translatesAutoresizingMaskIntoConstraints = false
        tabBarStack.setAccessibilityElement(true)
        tabBarStack.setAccessibilityRole(.list)
        tabBarStack.setAccessibilityLabel("Onglets ouverts")

        extensionBar.orientation = .horizontal
        extensionBar.spacing = 2
        extensionBar.alignment = .centerY
        extensionBar.translatesAutoresizingMaskIntoConstraints = false
        extensionBar.isHidden = true
        extensionBar.setAccessibilityLabel("Extensions")
        let body = NSStackView(views: [extensionBar, favoritesStack, tabBarStack])
        body.orientation = .vertical
        body.spacing = 10
        body.alignment = .leading
        body.translatesAutoresizingMaskIntoConstraints = false
        for view in [extensionBar, favoritesStack, tabBarStack] {
            view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = FlippedDocumentView()
        let document = scroll.documentView!
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            body.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        // Bottom bar: Favoris · Historique · Téléchargements · Liste de lecture, "N en veille" at the right.
        let panelBar = NSStackView()
        panelBar.orientation = .horizontal; panelBar.alignment = .centerY; panelBar.spacing = 2
        panelBar.translatesAutoresizingMaskIntoConstraints = false
        panelBar.addArrangedSubview(NSView())   // placeholder removed below
        panelBar.arrangedSubviews.forEach { panelBar.removeArrangedSubview($0); $0.removeFromSuperview() }
        let kinds: [(PanelKind, String, String)] = [(.favorites, "star", "Favoris"), (.history, "clock", "Historique  ⌘Y"),
                                                    (.downloads, "arrow.down.to.line", "Téléchargements"), (.reading, "text.book.closed", "Liste de lecture")]
        for (kind, symbol, label) in kinds {
            let b = ChromeIconButton(symbol: symbol, label: label, size: 30, pointSize: 13)
            b.onClick = { [weak self] in self?.togglePanel(kind) }
            panelButtons.append((kind, b))
            panelBar.addArrangedSubview(b)
        }
        let spacer = NSView(); spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        panelBar.addArrangedSubview(spacer)
        sleepMetaLabel.font = Theme.sans(11.5); sleepMetaLabel.textColor = Theme.muted
        sleepMetaLabel.translatesAutoresizingMaskIntoConstraints = false
        panelBar.addArrangedSubview(sleepMetaLabel)
        sidePanel.onBack = { [weak self] in self?.togglePanel(nil) }

        [topStack, searchRow, newTabRow, scroll, sidePanel, panelBar].forEach(column.addSubview)
        let rowsInset: CGFloat = 8
        NSLayoutConstraint.activate([
            topStack.topAnchor.constraint(equalTo: column.topAnchor, constant: 8),
            topStack.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 10),
            topStack.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor, constant: -10),

            searchRow.topAnchor.constraint(equalTo: topStack.bottomAnchor, constant: 12),
            searchRow.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: rowsInset),
            searchRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -rowsInset),
            newTabRow.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 2),
            newTabRow.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor),
            newTabRow.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: newTabRow.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: rowsInset),
            scroll.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -rowsInset),
            scroll.bottomAnchor.constraint(equalTo: panelBar.topAnchor, constant: -6),

            panelBar.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: rowsInset),
            panelBar.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -rowsInset),
            panelBar.bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: -10),
            panelBar.heightAnchor.constraint(equalToConstant: 34),

            sidePanel.topAnchor.constraint(equalTo: newTabRow.bottomAnchor, constant: 10),
            sidePanel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            sidePanel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            sidePanel.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
        ])
        tabColumn = column
        panelScroll = scroll

        [spaceRail, column, collapseButton].forEach(sidebar.addSubview)
        let rail = spaceRail.widthAnchor.constraint(equalToConstant: CGFloat(OreeTokens.Metrics.railWidth))
        railWidth = rail
        NSLayoutConstraint.activate([
            spaceRail.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            spaceRail.topAnchor.constraint(equalTo: sidebar.topAnchor),
            spaceRail.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            rail,

            column.leadingAnchor.constraint(equalTo: spaceRail.trailingAnchor),
            column.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            columnTopConstraint,
            column.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),

            collapseButton.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            collapseButton.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 12),
        ])

        refreshPinnedIcons()
        return sidebar
    }

    // MARK: - Side panels

    private func togglePanel(_ kind: PanelKind?) {
        activePanel = (kind == activePanel) ? nil : kind
        refreshPanel()
    }

    /// Shows the chosen panel in place of the tab list (or brings the tabs back).
    private func refreshPanel() {
        for (kind, button) in panelButtons { button.isActive = kind == activePanel }
        guard let kind = activePanel else {
            sidePanel.isHidden = true
            panelScroll?.isHidden = false
            return
        }
        panelScroll?.isHidden = true
        let open: (String) -> Void = { [weak self] url in self?.newTab(urlString: url, isPrivate: false) }
        switch kind {
        case .favorites:
            let items = ((try? bookmarkRepo.all(forSpace: currentSpace)) ?? []).map { b in
                PanelEntry(icon: .site(HomeFormatting.displayHost(b.url)), title: b.title.isEmpty ? HomeFormatting.displayHost(b.url) : b.title,
                           subtitle: HomeFormatting.displayHost(b.url), open: { open(b.url) },
                           remove: { [weak self] in try? self?.bookmarkRepo.remove(url: b.url); self?.menuBuilder?.refreshBookmarksMenu(); self?.refreshPinnedIcons(); self?.refreshPanel() })
            }
            sidePanel.show(title: "Favoris", sections: [PanelSection(title: nil, entries: items)], emptyText: "Aucun favori dans cet espace.")
        case .history:
            let entries = (try? historyRepo.recent(limit: 80)) ?? []
            let cal = Calendar.current
            func group(_ d: Date) -> String { cal.isDateInToday(d) ? "Aujourd’hui" : cal.isDateInYesterday(d) ? "Hier" : "Plus ancien" }
            var sections: [PanelSection] = []
            for name in ["Aujourd’hui", "Hier", "Plus ancien"] {
                let items = entries.filter { group($0.lastVisitedAt) == name && URL(string: $0.url)?.scheme != "oree" }.map { e in
                    PanelEntry(icon: .site(HomeFormatting.displayHost(e.url)), title: e.title.isEmpty ? HomeFormatting.displayHost(e.url) : e.title,
                               subtitle: "\(HomeFormatting.displayHost(e.url)) · \(HomeFormatting.relative(e.lastVisitedAt))", open: { open(e.url) }, remove: nil)
                }
                sections.append(PanelSection(title: name, entries: items))
            }
            sidePanel.show(title: "Historique", sections: sections, emptyText: "Rien dans l’historique pour l’instant.")
        case .downloads:
            let items = downloads.items.map { item in
                PanelEntry(icon: .symbol("doc"), title: item.name,
                           subtitle: item.phase == .running ? ByteFormat.progressLine(item.snapshot) : (item.phase == .finished ? "Terminé" : item.phase == .paused ? "En pause" : (item.error ?? "Échec")),
                           open: { [weak self] in if item.phase == .finished { self?.downloads.reveal(item.id) } }, remove: nil)
            }
            sidePanel.show(title: "Téléchargements", sections: [PanelSection(title: nil, entries: items)], emptyText: "Aucun téléchargement pour l’instant.")
        case .reading:
            let items = ((try? readingRepo.all()) ?? []).map { r in
                PanelEntry(icon: .site(HomeFormatting.displayHost(r.url)), title: r.title.isEmpty ? HomeFormatting.displayHost(r.url) : r.title,
                           subtitle: HomeFormatting.displayHost(r.url), open: { open(r.url) },
                           remove: { [weak self] in try? self?.readingRepo.remove(url: r.url); self?.refreshPanel() })
            }
            sidePanel.show(title: "Liste de lecture", sections: [PanelSection(title: nil, entries: items)],
                           emptyText: "Ajoutez des pages avec clic droit sur un onglet → « Ajouter à la liste de lecture ».")
        }
    }

    /// Clic droit / palette: keeps a page for later.
    func addToReadingList(_ tab: Tab) {
        guard let url = tab.currentURL, url.scheme == "http" || url.scheme == "https" else { return }
        try? readingRepo.add(url: url.absoluteString, title: tab.displayTitle)
        if activePanel == .reading { refreshPanel() }
    }

    @objc func openHistoryPanel() { activePanel = .history; refreshPanel() }

    // MARK: - Downloads

    private func downloadsChanged() {
        if activePanel == .downloads { refreshPanel() }
        let summary = downloads.summary
        downloadsButton.isHidden = !downloads.hasItems
        downloadsButton.ringIndeterminate = summary.running > 0 && summary.fraction == nil
        downloadsButton.ringProgress = summary.running > 0 && summary.fraction != nil ? summary.fraction : nil
        let tip = summary.running > 0 ? "Téléchargements — \(summary.running) en cours · \(ByteFormat.speed(summary.bytesPerSecond))" : "Téléchargements"
        downloadsButton.toolTip = tip
        downloadsButton.setAccessibilityLabel(tip + (summary.fraction.map { ", \(Int($0 * 100)) %" } ?? ""))
        downloadsPanel?.refresh()
        if let popover = downloadsPopover, popover.isShown, let panel = downloadsPanel { popover.contentSize = panel.frame.size }
    }

    private func toggleDownloads() {
        if let popover = downloadsPopover, popover.isShown { popover.close(); return }
        let popover = NSPopover()
        popover.behavior = .transient
        let panel = DownloadsPanelView(controller: downloads)
        let controller = NSViewController()
        controller.view = panel
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: DownloadsPanelView.width, height: panel.frame.height)
        popover.show(relativeTo: downloadsButton.bounds, of: downloadsButton, preferredEdge: .maxY)
        downloadsPopover = popover
        downloadsPanel = panel
    }

    // MARK: - Split screen

    private func splitContains(_ id: UUID) -> Bool { splitPair.map { $0.left == id || $0.right == id } ?? false }

    /// A tab shown in the split screen but not focused is still on screen: never put it to sleep.
    private func isOnScreen(_ tab: Tab) -> Bool { tab.id == activeTabID || splitContains(tab.id) }

    private func ensureAwake(_ tab: Tab) {
        if tab.isFrozen { tab.thaw() }   // instant: the page was only paused
        guard tab.isSuspended else { return }
        let webView = tab.wake()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// ⌘\ — split with the most recently used other tab of the space (or a fresh tab); again to leave.
    @objc func toggleSplit() {
        if splitPair != nil { endSplit(keeping: activeTabID); return }
        guard let active = activeTab else { return }
        let candidate = visibleTabs()
            .filter { $0.id != active.id && $0.isPrivate == active.isPrivate }
            .max { $0.lastActiveDate < $1.lastActiveDate }
        let partner = candidate ?? newTab(urlString: nil, isPrivate: active.isPrivate)
        beginSplit(left: active, right: partner)
    }

    private func beginSplit(left: Tab, right: Tab) {
        guard left.id != right.id, left.spaceIndex == right.spaceIndex else { return }
        if splitPair != nil { endSplit(keeping: left.id) }
        for tab in [left, right] { ensureAwake(tab); tab.contentSlot.isHidden = false }
        splitPair = (left.id, right.id)
        splitRatio = 0.5
        splitButton.isActive = true
        installSplitLayout()
        saveSession()
        splitMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.focusPane(at: event) }
            return event
        }
        selectTab(left)
    }

    /// Re-pins the two slots side by side, with a header over each and the hinge between them.
    private func installSplitLayout() {
        guard let pair = splitPair,
              let left = tabs.first(where: { $0.id == pair.left }), let right = tabs.first(where: { $0.id == pair.right }) else { return }
        NSLayoutConstraint.deactivate(splitConstraints); splitConstraints = []
        splitHeaders.values.forEach { $0.removeFromSuperview() }; splitHeaders = [:]
        splitHinge?.removeFromSuperview()

        let headerHeight: CGFloat = 34, hingeWidth: CGFloat = 40
        left.slotTrailing?.isActive = false
        right.slotLeading?.isActive = false
        left.slotTop?.constant = headerHeight
        right.slotTop?.constant = headerHeight

        let leftWidth = left.contentSlot.widthAnchor.constraint(equalTo: contentContainer.widthAnchor, multiplier: splitRatio, constant: -6)
        splitLeftWidth = leftWidth
        let rightLeading = right.contentSlot.leadingAnchor.constraint(equalTo: left.contentSlot.trailingAnchor, constant: 12)
        splitConstraints += [leftWidth, rightLeading]

        let hinge = SplitHingeView()
        hinge.ratio = splitRatio
        hinge.onRatio = { [weak self] ratio, final in self?.setSplitRatio(ratio, animated: final) }
        hinge.onSwap = { [weak self] in self?.swapSplit() }
        splitHinge = hinge
        contentContainer.addSubview(hinge)
        splitConstraints += [
            hinge.widthAnchor.constraint(equalToConstant: hingeWidth),
            hinge.centerXAnchor.constraint(equalTo: left.contentSlot.trailingAnchor, constant: 6),
            hinge.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: headerHeight),
            hinge.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ]

        for (tab, side) in [(left, 0), (right, 1)] {
            let header = SplitPaneHeader()
            header.onFocus = { [weak self, weak tab] in if let tab { self?.selectTab(tab) } }
            header.onSolo = { [weak self, weak tab] in if let tab { self?.endSplit(keeping: tab.id) } }
            header.onClose = { [weak self, weak tab] in
                guard let self, let tab, let pair = self.splitPair else { return }
                self.endSplit(keeping: tab.id == pair.left ? pair.right : pair.left)
            }
            contentContainer.addSubview(header, positioned: .below, relativeTo: loadingBar)
            splitHeaders[tab.id] = header
            splitConstraints += [
                header.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                header.leadingAnchor.constraint(equalTo: tab.contentSlot.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: tab.contentSlot.trailingAnchor),
            ]
            _ = side
        }
        NSLayoutConstraint.activate(splitConstraints)
        refreshSplitHeaders()
        contentContainer.layoutSubtreeIfNeeded()
    }

    private func refreshSplitHeaders() {
        guard splitPair != nil else { return }
        for (id, header) in splitHeaders {
            guard let tab = tabs.first(where: { $0.id == id }) else { continue }
            header.configure(title: tab.displayTitle, host: tab.badgeHost)
            header.isFocused = id == activeTabID
        }
        splitHinge?.ratio = splitRatio
    }

    private func setSplitRatio(_ ratio: CGFloat, animated: Bool) {
        splitRatio = ratio
        guard let old = splitLeftWidth, let pair = splitPair, let left = tabs.first(where: { $0.id == pair.left }) else { return }
        let new = left.contentSlot.widthAnchor.constraint(equalTo: contentContainer.widthAnchor, multiplier: ratio, constant: -6)
        NSLayoutConstraint.deactivate([old]); splitConstraints.removeAll { $0 === old }
        new.isActive = true; splitConstraints.append(new); splitLeftWidth = new
        if animated {
            Motion.animate(Motion.standard) { contentContainer.animator().layoutSubtreeIfNeeded() }
        } else {
            contentContainer.layoutSubtreeIfNeeded()
        }
        splitHinge?.ratio = ratio
        if animated { saveSession() }
    }

    private func swapSplit() {
        guard let pair = splitPair else { return }
        splitPair = (pair.right, pair.left)
        installSplitLayout()
        saveSession()
    }

    /// Back to a single page. `keeping` is the tab that stays visible (nil = the focused one).
    private func endSplit(keeping id: UUID?) {
        guard let pair = splitPair else { return }
        if let splitMonitor { NSEvent.removeMonitor(splitMonitor) }
        splitMonitor = nil
        NSLayoutConstraint.deactivate(splitConstraints); splitConstraints = []
        splitHeaders.values.forEach { $0.removeFromSuperview() }; splitHeaders = [:]
        splitHinge?.removeFromSuperview(); splitHinge = nil
        splitLeftWidth = nil
        splitPair = nil
        splitButton.isActive = false
        let keep = id ?? activeTabID
        for tab in tabs where tab.id == pair.left || tab.id == pair.right {
            tab.slotTop?.constant = 0
            tab.slotLeading?.isActive = true
            tab.slotTrailing?.isActive = true
            tab.contentSlot.isHidden = tab.id != keep
        }
        contentContainer.layoutSubtreeIfNeeded()
        if let keep, let tab = tabs.first(where: { $0.id == keep }), activeTabID != keep { selectTab(tab) }
        saveSession()
    }

    /// A click inside one of the two sides focuses it (web views swallow the click, so we peek at it).
    private func focusPane(at event: NSEvent) {
        guard let pair = splitPair, event.window === window else { return }
        let point = contentContainer.convert(event.locationInWindow, from: nil)
        guard contentContainer.bounds.contains(point) else { return }
        for id in [pair.left, pair.right] {
            guard let tab = tabs.first(where: { $0.id == id }), id != activeTabID else { continue }
            if tab.contentSlot.frame.contains(point) { selectTab(tab); return }
        }
    }

    /// Shows the welcome once (never in scripted runs, which always start fresh).
    public func showOnboardingIfNeeded() {
        guard !SettingsStore.shared.onboardingDone, !isFreshSession else { return }
        onboarding.present()
    }

    /// Daily, silent unless a newer version exists.
    public func checkForUpdatesInBackground() { AppUpdater.shared.checkInBackgroundIfDue() }

    @objc func checkForUpdates() { AppUpdater.shared.checkNow() }

    @objc func showAbout() { AboutPanel.shared.present() }

    /// Automation only.
    @objc func automationOnboarding() { onboarding.present() }

    // MARK: - Spaces overview

    /// ⌃↑
    @objc func openOverview() {
        palette.isHidden = true
        overview.present()
    }

    private func closeOverview() {
        overview.dismiss()
        if let webView = activeTab?.webView { window?.makeFirstResponder(webView) }
    }

    private func overviewCards() -> [SpaceCardData] {
        spaces.enumerated().map { index, style in
            let mine = tabs.filter { $0.spaceIndex == index }
            let groupNames = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.name) })
            // Grouped tabs first (in group order), then loose ones — collapsed groups still list their tabs.
            let grouped = groups.filter { $0.spaceIndex == index }.flatMap { group in mine.filter { $0.groupID == group.id } }
            let groupedIDs = Set(grouped.map(\.id))
            let ordered = grouped + mine.filter { !groupedIDs.contains($0.id) }
            let entries = ordered.map { tab in
                SpaceCardData.Entry(title: tab.displayTitle, host: tab.badgeHost, sleeping: tab.isSuspended,
                                    group: tab.groupID.flatMap { groupedIDs.contains(tab.id) ? groupNames[$0] : nil })
            }
            return SpaceCardData(index: index, style: style, entries: entries, isCurrent: index == currentSpace)
        }
    }

    /// Removes a space; its tabs move to the neighbouring one (nothing the user opened is lost).
    private func deleteSpace(_ index: Int) {
        guard spaces.count > 1, spaces.indices.contains(index) else { return }
        for tab in tabs { tab.spaceIndex = SpaceReindex.newIndex(tab.spaceIndex, afterDeleting: index) }
        let removedGroups = Set(groups.filter { $0.spaceIndex == index }.map(\.id))
        for tab in tabs where tab.groupID.map(removedGroups.contains) == true { tab.groupID = nil }
        groups.removeAll { removedGroups.contains($0.id) }
        for i in groups.indices { groups[i].spaceIndex = SpaceReindex.newIndex(groups[i].spaceIndex, afterDeleting: index) }
        closedTabs = closedTabs.map { ($0.url, $0.state, $0.title, SpaceReindex.newIndex($0.space, afterDeleting: index)) }
        var remembered: [Int: UUID] = [:]
        for (space, id) in lastActiveTabInSpace where space != index { remembered[SpaceReindex.newIndex(space, afterDeleting: index)] = id }
        lastActiveTabInSpace = remembered
        try? bookmarkRepo.reindex(afterDeletingSpace: index)
        spaces.remove(at: index)
        currentSpace = SpaceReindex.newIndex(currentSpace, afterDeleting: index)
        UserDefaults.standard.set(currentSpace, forKey: Self.activeSpaceKey)
        refreshSpaceUI(animated: false)
        saveSession()
    }

    // MARK: - Customization drawer

    /// ⌘,
    @objc func openCustomize() {
        palette.isHidden = true
        drawer.present()
        window?.makeFirstResponder(drawer)
    }

    private func closeCustomize() {
        drawer.dismiss()
        if let webView = activeTab?.webView { window?.makeFirstResponder(webView) }
    }

    private func pickHomePhoto() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .webP]
        panel.allowsMultipleSelection = false
        panel.message = "Choisissez la photo de la page d’accueil"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                SettingsStore.shared.homePhotoPath = url.path
                SettingsStore.shared.homeBackground = .photo
                self?.drawer.refreshFromSettings()
                self?.applyLookChanges()
            }
        }
    }

    /// Pushes the look settings (theme, accent, density, radius, text size, sidebar, home) into the live window.
    private func applyLookChanges() {
        let store = SettingsStore.shared
        lastLook = LookProfile.capture(named: "", from: store)
        lastSidebarPrefs = [store.sidebarWidth, store.sidebarGlass ? 1 : 0]
        Theme.applyAppearance(store.appearanceMode)
        Theme.accentHue = store.accentHue
        Theme.density = store.density
        Theme.radiusBase = store.cornerRadius
        Theme.textOffset = CGFloat(store.uiTextOffset)

        for tab in tabs { tab.tabButton.refreshMetrics() }
        searchRow?.refreshMetrics()
        newTabRow?.refreshMetrics()
        addressPill.refreshMetrics()
        spaceNameLabel.font = Theme.Typo.subheading
        spaceMetaLabel.font = Theme.sans(12)
        applySidebarMode(animated: true)
        refreshSpaceUI(animated: false)
        for tab in tabs { tab.contentSlot.needsDisplay = true }
        reloadHomePages()
        NotificationCenter.default.post(name: Theme.didChange, object: nil)
    }

    /// Re-renders open home pages so they pick up background, toggles, accent and radius.
    private func reloadHomePages() {
        for tab in tabs where tab.webView?.url?.scheme == "oree" {
            tab.webView?.loadHTMLString(StartPage.render(homeInput(for: tab)), baseURL: StartPage.baseURL)
        }
    }

    // MARK: - Sidebar modes

    /// What is actually shown: the chosen mode, except that narrow windows fall back to compact.
    private var effectiveSidebarMode: SidebarMode {
        BrowserCore.effectiveSidebarMode(SettingsStore.shared.sidebarMode, windowWidth: Double(window?.frame.width ?? 1280))
    }

    /// Width of the expanded sidebar (user-resizable by dragging its right edge).
    private var expandedSidebarWidth: CGFloat { CGFloat(SettingsStore.shared.sidebarWidth) }

    private func applySidebarMode(animated: Bool) {
        let store = SettingsStore.shared
        let horizontal = store.tabLayout == .horizontal
        let mode: SidebarMode = horizontal ? .hidden : effectiveSidebarMode
        let compact = mode == .compact
        let hover = mode == .floating                          // hidden until the pointer touches the left edge
        let hidden = mode == .hidden
        let outOfLayout = hidden || hover                      // sidebar is not a column of the layout
        // Title row: 52 pt with the system-centered traffic lights; 44 pt in full screen (no lights, no title bar).
        let bar = isFullScreen ? CGFloat(OreeTokens.Metrics.stackedToolbarHeight) : CGFloat(OreeTokens.Metrics.toolbarHeight)
        spaceRail.setTopInset(isFullScreen ? 10 : bar)
        columnTop?.constant = isFullScreen ? 10 : bar
        resizeHandleTop?.constant = isFullScreen ? 10 : bar
        stripHeight?.constant = horizontal ? bar : 0
        toolbar.setHeight(horizontal ? CGFloat(OreeTokens.Metrics.stackedToolbarHeight) : bar)
        tabStrip.isHidden = !horizontal
        tabStrip.setLeadingInset(isFullScreen ? 12 : 92)
        // Hover panel is the concise version: no 52 pt rail, spaces become a row of icons, so it is narrower.
        let railW = CGFloat(OreeTokens.Metrics.railWidth)
        let width: CGFloat = compact ? CGFloat(OreeTokens.Metrics.compactSidebarWidth) + 2
            : hover ? max(expandedSidebarWidth - railW, CGFloat(SidebarWidth.minimum) - railW) : expandedSidebarWidth
        if !hover {
            floatingShown = false
            floatingShowWork?.cancel(); floatingHideWork?.cancel()
            if let monitor = floatingClickMonitor { NSEvent.removeMonitor(monitor); floatingClickMonitor = nil }
        }
        spaceRail.configure(spaces: spaces, selected: currentSpace, compact: compact)
        spaceRail.isHidden = hover
        refreshHoverSpaceRow()
        hoverSpaceRow.isHidden = !hover
        updateTabCount()
        railWidth?.constant = compact ? width : (hover ? 0 : railW)
        tabColumn?.isHidden = compact
        collapseButton.isHidden = compact || hidden || hover
        collapseButton.toolTip = "Réduire la barre latérale"
        resizeHandle.isHidden = compact || hidden
        // The toolbar's sidebar button: brings back a hidden / hover / compact sidebar.
        let showToggle = !horizontal && (hidden || hover || store.sidebarMode == .compact)
        toggleSidebarButton.isHidden = !showToggle
        toggleSidebarButton.toolTip = compact ? "Agrandir la barre latérale  ⌥⌘S" : "Afficher la barre latérale  ⌥⌘S"
        let lightsClear: CGFloat = isFullScreen ? 12 : 92                            // room for the traffic lights when the toolbar starts at x = 0
        // Compact: the toolbar starts at the 58 pt rail, so its first button needs less inset to clear the lights.
        toolbar.setLeadingInset(horizontal ? 8 : (hidden || hover) ? lightsClear : (compact ? max(lightsClear - 58, 8) : 8))
        edgeTrigger.isHidden = !hover
        let visibleOverlay = hover && floatingShown

        // Surface: a rounded, inset glass (or solid) panel while it hovers over the page; edge-to-edge otherwise.
        let glass = hover && store.sidebarGlass
        let inset: CGFloat = hover ? 8 : 0
        sidebarGlassView.isHidden = !glass
        if let surface = sidebarView as? SurfaceView {
            surface.fill = (hover && !glass) ? Theme.chrome : nil
            surface.cornerRadius = hover ? 20 : 0
            surface.clips = hover
            surface.border = hover ? Theme.line : nil
            surface.elevation = nil
        }
        sidebarTop?.constant = inset
        sidebarBottom?.constant = -inset
        Motion.animate(animated ? Motion.slow : 0) {
            let w = animated ? sidebarWidth?.animator() : sidebarWidth
            w?.constant = width
            (animated ? mainLeading?.animator() : mainLeading)?.constant = outOfLayout ? 0 : width
            let hiddenOffset = -(width + 40)
            (animated ? sidebarLeading?.animator() : sidebarLeading)?.constant = visibleOverlay ? inset : (outOfLayout ? hiddenOffset : 0)
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// Compact row of space icons (+ overview) shown at the top of the hover panel instead of the rail.
    private func refreshHoverSpaceRow() {
        hoverSpaceRow.arrangedSubviews.forEach { hoverSpaceRow.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (index, space) in spaces.enumerated() {
            let spine = SpineButton(space: space, shortcut: "⌃\(index + 1)")
            spine.iconOnly = true
            spine.isSelected = index == currentSpace
            spine.onClick = { [weak self] in self?.selectSpace(index) }
            spine.contextMenuProvider = { [weak self] in
                let menu = NSMenu()
                menu.addItem(ClosureMenuItem(title: "Modifier l’espace…") { self?.openOverview() })
                return menu
            }
            hoverSpaceRow.addArrangedSubview(spine)
        }
        let overview = ChromeIconButton(symbol: "square.grid.2x2", label: "Vue d’ensemble des espaces  ⌃↑", size: 36, pointSize: 14)
        overview.onClick = { [weak self] in self?.openOverview() }
        hoverSpaceRow.addArrangedSubview(overview)
        let settings = ChromeIconButton(symbol: "gearshape", label: "Réglages  ⇧⌘,", size: 36, pointSize: 14)
        settings.onClick = { [weak self] in self?.openSettings() }
        hoverSpaceRow.addArrangedSubview(settings)
    }

    /// Live resize while the handle is dragged; the width is saved when released.
    private func resizeSidebar(toRight x: CGFloat, final: Bool) {
        guard let sidebar = sidebarView else { return }
        let left = sidebar.frame.minX
        let width = CGFloat(SidebarWidth.clamp(Double(x - left)))
        sidebarWidth?.constant = width
        if !effectiveSidebarMode.overlaysPage { mainLeading?.constant = width }
        window?.contentView?.layoutSubtreeIfNeeded()
        if final { SettingsStore.shared.sidebarWidth = Double(width) }
    }

    // MARK: Hover sidebar

    private var pointerInSidebar: Bool {
        guard let window, let sidebar = sidebarView, let content = window.contentView else { return false }
        let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return sidebar.frame.insetBy(dx: -4, dy: -4).contains(point)
    }

    private var pointerInEdgeZone: Bool {
        guard let window, let content = window.contentView else { return false }
        let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return edgeTrigger.frame.insetBy(dx: -2, dy: 0).contains(point)
    }

    /// The pointer touched the left edge: show the panel if it is still there after a short moment (not when merely passing by).
    private func scheduleFloatingShow() {
        guard effectiveSidebarMode == .floating, !floatingShown else { return }
        floatingShowWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pointerInEdgeZone else { return }
                self.setFloatingShown(true)
                self.scheduleFloatingHide(after: 1.5)       // safety net if the pointer never enters the panel
            }
        }
        floatingShowWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Hides the panel after `delay`, unless the pointer is back on it, a menu is open or its edge is being dragged.
    private func scheduleFloatingHide(after delay: TimeInterval) {
        guard floatingShown else { return }
        floatingHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.floatingShown else { return }
                if self.pointerInSidebar || self.pointerInEdgeZone || self.floatingMenuTracking || self.isResizingSidebar { return }
                self.setFloatingShown(false)
            }
        }
        floatingHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Slides the panel in or out. Only the position moves — nothing is rebuilt, so there is no flicker.
    private func setFloatingShown(_ shown: Bool) {
        guard effectiveSidebarMode == .floating, floatingShown != shown else { return }
        floatingShown = shown
        floatingShowWork?.cancel(); floatingHideWork?.cancel()
        let width = sidebarWidth?.constant ?? expandedSidebarWidth
        let target: CGFloat = shown ? 8 : -(width + 40)
        Motion.animate(shown ? Motion.standard : Motion.quick) {
            sidebarLeading?.animator().constant = target
            window?.contentView?.layoutSubtreeIfNeeded()
        }
        if shown {
            // A click anywhere outside the panel puts it away (the click still goes through to the page).
            floatingClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let content = self.window?.contentView, event.window === self.window,
                          let sidebar = self.sidebarView else { return }
                    let point = content.convert(event.locationInWindow, from: nil)
                    if !sidebar.frame.contains(point) { self.setFloatingShown(false) }
                }
                return event
            }
        } else if let monitor = floatingClickMonitor {
            NSEvent.removeMonitor(monitor)
            floatingClickMonitor = nil
        }
    }

    /// ⌘⇧S / ⌥⌘S: hide or bring back the sidebar (in floating mode: show or tuck away the overlay).
    @objc func toggleSidebar() {
        let store = SettingsStore.shared
        if store.tabLayout == .horizontal { return }
        if store.sidebarMode == .floating { setFloatingShown(!floatingShown); return }
        if store.sidebarMode == .compact { store.sidebarMode = .fixed; applySidebarMode(animated: true); return }
        if store.sidebarMode == .hidden {
            let back = SidebarMode(rawValue: UserDefaults.standard.string(forKey: "sidebar.modeBeforeHide") ?? "") ?? .fixed
            store.sidebarMode = back == .hidden ? .fixed : back
        } else {
            UserDefaults.standard.set(store.sidebarMode.rawValue, forKey: "sidebar.modeBeforeHide")
            store.sidebarMode = .hidden
        }
        applySidebarMode(animated: true)
    }

    /// The button in the sidebar header: icons-only ↔ full width.
    private func toggleCompactSidebar() {
        let store = SettingsStore.shared
        if store.sidebarMode == .floating { store.sidebarMode = .fixed; applySidebarMode(animated: true); return }
        store.sidebarMode = (store.sidebarMode == .compact) ? .fixed : .compact
        applySidebarMode(animated: true)
    }

    /// Automation only: puts the first two tabs of the space into a "Recherche" group.
    @objc func automationDemoGroup() {
        let group = TabGroup(name: "Recherche", spaceIndex: currentSpace)
        groups.append(group)
        for tab in visibleTabs().prefix(2) { tab.groupID = group.id }
        rebuildTabList()
        saveSession()
    }

    /// Automation only: collapses/expands the first group.
    @objc func automationToggleFirstGroup() { if let g = groups.first { toggleGroup(g.id) } }

    /// Automation only: shrinks the window to exercise the narrow (auto-compact) layout.
    /// Automation only: where the traffic lights really are (window coordinates, from the top).
    @objc func automationLights() {
        guard let window else { return }
        var text = "windowH=\(window.frame.height) layoutRect=\(window.contentLayoutRect)\n"
        for type in [NSWindow.ButtonType.closeButton, .zoomButton] {
            guard let b = window.standardWindowButton(type), let sv = b.superview else { continue }
            let inWindow = sv.convert(b.frame, to: nil)
            text += "\(type.rawValue): centerFromTop=\(window.frame.height - inWindow.midY) frame=\(b.frame) bar=\(sv.frame) \(sv.className) container=\(String(describing: sv.superview?.frame))\n"
        }
        try? text.write(toFile: "/tmp/hb-lights.txt", atomically: true, encoding: .utf8)
    }

    /// Automation only: shows the downloads panel inside the window so a snapshot can capture it (popovers are separate windows).
    private var demoPanel: DownloadsPanelView?
    @objc func automationDownloadsPanelDemo() {
        guard let content = window?.contentView else { return }
        demoPanel?.removeFromSuperview()
        let panel = DownloadsPanelView(controller: downloads)
        panel.wantsLayer = true
        panel.layer?.backgroundColor = Theme.cg(Theme.raised, in: panel)
        panel.layer?.cornerRadius = 14
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = Theme.cg(Theme.line, in: panel)
        content.addSubview(panel)
        NSLayoutConstraint.activate([panel.topAnchor.constraint(equalTo: content.topAnchor, constant: 60), panel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16)])
        demoPanel = panel
        downloads.onChange = { [weak self] in self?.downloadsChanged(); self?.demoPanel?.refresh() }
    }

    @objc func automationDownloadsDump() { try? downloads.debugDescription().write(toFile: "/tmp/hb-downloads.txt", atomically: true, encoding: .utf8) }
    @objc func automationPauseDownload() { if let id = downloads.debugFirstID() { downloads.pause(id) } }
    @objc func automationResumeDownload() { if let id = downloads.debugFirstID() { downloads.resume(id) } }
    @objc func automationCancelDownload() { if let id = downloads.debugFirstID() { downloads.cancel(id) } }

    @objc func automationBraveDiag() {
        try? ChromiumCookies.diagnose().joined(separator: "\n").write(toFile: "/tmp/hb-brave-diag.txt", atomically: true, encoding: .utf8)
    }

    @objc func automationNarrowWindow() {
        guard var frame = window?.frame else { return }
        frame.size.width = 820
        window?.setFrame(frame, display: true)
    }

    // Full screen has no title bar: drop the (empty) toolbar that would otherwise slide down over our own,
    // and use the compact 44 pt title row. Both come back when leaving full screen.
    public func windowWillEnterFullScreen(_ notification: Notification) {
        isFullScreen = true
        window?.toolbar = nil
        applySidebarMode(animated: false)
    }
    public func windowDidEnterFullScreen(_ notification: Notification) { applySidebarMode(animated: false) }
    public func windowWillExitFullScreen(_ notification: Notification) {
        isFullScreen = false
        window?.toolbar = titleToolbar
        window?.toolbarStyle = .unified
        applySidebarMode(animated: false)
    }
    public func windowDidExitFullScreen(_ notification: Notification) {
        // The title bar only takes the toolbar once the transition is over; re-attach it so the traffic lights re-center.
        isFullScreen = false
        window?.toolbar = nil
        window?.toolbar = titleToolbar
        window?.toolbarStyle = .unified
        applySidebarMode(animated: false)
    }

    public func windowDidResize(_ notification: Notification) {
        applySidebarMode(animated: false)
    }

    /// Favorites grid: three equal columns right under the search field.
    func refreshPinnedIcons() {
        favoritesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let bookmarks = (try? bookmarkRepo.all(forSpace: currentSpace)) ?? []

        // One cell per favorite, plus a final "+" cell that adds the current page.
        var cells: [NSView] = bookmarks.map { bookmark in
            let tile = FavoriteTileView(url: bookmark.url, title: bookmark.title)
            tile.onClick = { [weak self] in self?.newTab(urlString: bookmark.url, isPrivate: false) }
            tile.contextMenuProvider = { [weak self] in self?.makeFavoriteMenu(for: bookmark) }
            return tile
        }
        let addTile = AddFavoriteTileView()
        addTile.onClick = { [weak self] in
            guard let self, let tab = self.activeTab else { return }
            self.toggleBookmark(for: tab, forceAdd: true)
        }
        cells.append(addTile)

        var delay = 0.0
        for start in stride(from: 0, to: cells.count, by: 4) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            for column in 0..<4 {
                guard start + column < cells.count else {
                    row.addArrangedSubview(NSView())   // keeps the last row's tiles the same width
                    continue
                }
                let cell = cells[start + column]
                cell.alphaValue = 0
                Motion.animate(Motion.standard + delay) { cell.animator().alphaValue = 1 }
                delay += 0.02
                row.addArrangedSubview(cell)
            }
            favoritesStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: favoritesStack.widthAnchor).isActive = true
        }
    }

    private func makeFavoriteMenu(for bookmark: Bookmark) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping @MainActor () -> Void) {
            menu.addItem(ClosureMenuItem(title: title, action: action))
        }
        add("Ouvrir dans un nouvel onglet") { [weak self] in self?.newTab(urlString: bookmark.url, isPrivate: false) }
        add("Copier le lien") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(bookmark.url, forType: .string)
        }
        menu.addItem(.separator())
        add("Retirer des favoris") { [weak self] in
            try? self?.bookmarkRepo.remove(url: bookmark.url)
            self?.menuBuilder?.refreshBookmarksMenu()
            self?.refreshPinnedIcons()
        }
        return menu
    }

    /// Adds the tab's page to the favorites, or removes it if it's already there
    /// (`forceAdd` never removes — used by the "+" tile).
    func toggleBookmark(for tab: Tab, forceAdd: Bool = false) {
        guard let url = tab.currentURL, url.scheme == "http" || url.scheme == "https" else { return }
        let key = url.absoluteString
        do {
            if try bookmarkRepo.contains(url: key) {
                guard !forceAdd else { return }
                try bookmarkRepo.remove(url: key)
            } else {
                try bookmarkRepo.add(url: key, title: tab.displayTitle, spaceIndex: currentSpace)
            }
        } catch {
            Log.storage.error("Failed to toggle bookmark: \(error.localizedDescription)")
        }
        menuBuilder?.refreshBookmarksMenu()
        refreshPinnedIcons()
    }

    // MARK: - Password manager

    /// Saved logins only ever apply to a secure origin (or a local dev server).
    private func isEligibleForCredentials(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host else { return false }
        if url.scheme == "https" { return true }
        return url.scheme == "http" && (host == "localhost" || host == "127.0.0.1")
    }

    private func handleCredentialMessage(webView: WKWebView, origin: String, body: [String: Any]) {
        guard isEligibleForCredentials(origin), let tab = tab(for: webView),
              let type = body["type"] as? String else { return }
        switch type {
        case "focus":
            Task { await offerAutofill(in: tab, webView: webView, origin: origin) }
        case "submit":
            guard !tab.isPrivate,
                  let username = body["username"] as? String, let password = body["password"] as? String,
                  !password.isEmpty, password.count < 1024, username.count < 512 else { return }
            Task { await offerToSave(origin: origin, username: username, password: password) }
        default:
            break
        }
    }

    private func offerAutofill(in tab: Tab, webView: WKWebView, origin: String) async {
        guard !credentialPromptInFlight else { return }
        let logins = (try? vault.logins(forOrigin: origin)) ?? []
        guard !logins.isEmpty else { return }
        credentialPromptInFlight = true
        defer { credentialPromptInFlight = false }

        let host = URL(string: origin)?.host ?? origin
        guard let login = logins.count == 1 ? logins[0] : await chooseLogin(logins, host: host) else { return }
        guard await VaultUnlocker.shared.authenticate(reason: "Remplir le mot de passe de \(login.username) pour \(host)") else { return }
        do {
            guard let password = try vault.password(origin: origin, username: login.username) else { return }
            _ = try? await webView.callAsyncJavaScript(
                "return window.__hbFill(u, p);",
                arguments: ["u": login.username, "p": password],
                in: nil, contentWorld: .page
            )
        } catch {
            Log.security.error("Autofill failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func chooseLogin(_ logins: [SavedLogin], host: String) async -> SavedLogin? {
        guard let window else { return nil }
        let alert = NSAlert()
        alert.messageText = "Quel compte utiliser pour « \(host) » ?"
        alert.addButton(withTitle: "Remplir")
        alert.addButton(withTitle: "Annuler")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        popup.addItems(withTitles: logins.map(\.username))
        alert.accessoryView = popup
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        guard response == .alertFirstButtonReturn, logins.indices.contains(popup.indexOfSelectedItem) else { return nil }
        return logins[popup.indexOfSelectedItem]
    }

    private func offerToSave(origin: String, username: String, password: String) async {
        let key = "\(origin)\u{0}\(username)"
        guard !credentialPromptInFlight, !declinedSaves.contains(key), let window else { return }
        let existing = try? vault.password(origin: origin, username: username)
        if existing == password { return }

        credentialPromptInFlight = true
        defer { credentialPromptInFlight = false }
        let host = URL(string: origin)?.host ?? origin
        let isUpdate = existing != nil
        let alert = NSAlert()
        alert.messageText = isUpdate ? "Mettre à jour le mot de passe ?" : "Enregistrer le mot de passe ?"
        alert.informativeText = username.isEmpty
            ? "Pour « \(host) ». Il sera chiffré et protégé par Touch ID."
            : "Compte « \(username) » sur « \(host) ». Il sera chiffré et protégé par Touch ID."
        alert.addButton(withTitle: isUpdate ? "Mettre à jour" : "Enregistrer")
        alert.addButton(withTitle: "Pas maintenant")
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        guard response == .alertFirstButtonReturn else { declinedSaves.insert(key); return }
        do {
            try vault.save(origin: origin, username: username, password: password)
        } catch {
            Log.security.error("Saving credential failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Command palette

    /// ⌘Y — the palette, already filtered on history.
    @objc func openHistoryAction() {
        palette.present(initialText: "", selectAll: false, opensInNewTab: true, in: window)
        palette.setFilter(.history)
    }

    /// ⇧⌘L — Clair → Sombre → Auto.
    @objc func cycleTheme() {
        let all = AppearanceMode.allCases
        let store = SettingsStore.shared
        store.appearanceMode = all[((all.firstIndex(of: store.appearanceMode) ?? 0) + 1) % all.count]
        applyLookChanges()
        if drawerLoaded { drawer.refreshFromSettings() }
    }

    /// ⌘K
    @objc func openPaletteAction() {
        openPalette(initialText: "", selectAll: false, opensInNewTab: true)
    }

    /// ⌘L — edit the address in the toolbar, with suggestions underneath.
    @objc func focusAddressBar() {
        if drawerLoaded, drawer.isPresented { closeCustomize() }
        let url = activeTab?.currentURL
        let text = (url?.scheme == "http" || url?.scheme == "https") ? (url?.absoluteString ?? "") : ""
        addressPill.beginEditing(text: text)
    }

    private func refreshAddressSuggestions(_ query: String) {
        let sections = paletteSections(query: query.trimmingCharacters(in: .whitespacesAndNewlines), filter: .all)
            .filter { $0.title != "Actions" && $0.title != "Espaces" && $0.title != "Favoris" }
        addressDropdown.show(sections)
    }

    private func endAddressEditing() {
        addressPill.endEditing()
        addressDropdown.hide()
        if let webView = activeTab?.webView, window?.firstResponder is NSText || window?.firstResponder === window { window?.makeFirstResponder(webView) }
    }

    private func commitAddress(_ text: String, newTab: Bool) {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Like the palette: Return runs the highlighted suggestion (the first one unless arrowed).
        if let item = addressDropdown.selectedItem, addressDropdown.hasSelection, !raw.isEmpty {
            endAddressEditing(); item.perform(newTab); return
        }
        endAddressEditing()
        guard !raw.isEmpty else { return }
        openFromPalette(raw, inNewTab: newTab)
    }

    private func openPalette(initialText: String, selectAll: Bool, opensInNewTab: Bool) {
        palette.present(initialText: initialText, selectAll: selectAll, opensInNewTab: opensInNewTab, in: window)
    }

    private func closePalette() {
        palette.dismiss(restoringFocusTo: activeTab?.webView)
    }

    private func openFromPalette(_ raw: String, inNewTab: Bool) {
        if inNewTab || activeTab == nil {
            newTab(urlString: raw, isPrivate: SettingsStore.shared.privateByDefault)
        } else if let tab = activeTab {
            load(urlString: raw, in: tab)
        }
    }

    private func paletteSections(query: String, filter: PaletteFilter) -> [PaletteSection] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ values: String...) -> Bool {
            q.isEmpty || values.contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        var sections: [PaletteSection] = []

        if filter == .all, !q.isEmpty {
            let isAddress = Self.looksLikeAddress(q)
            sections.append(PaletteSection(title: isAddress ? "Ouvrir" : "Rechercher", items: [
                PaletteItem(
                    icon: .symbol(isAddress ? "arrow.up.right" : "magnifyingglass"),
                    title: isAddress ? q : "« \(q) » sur le web",
                    subtitle: nil,
                    trailing: "↵",
                    perform: { [weak self] inNewTab in self?.openFromPalette(q, inNewTab: inNewTab) }
                ),
            ]))
        }

        if filter == .all || filter == .tabs {
            let found = tabs.filter { matches($0.displayTitle, $0.currentURL?.absoluteString ?? "") }
            sections.append(PaletteSection(title: "Onglets ouverts", items: found.map { tab in
                PaletteItem(
                    icon: .site(host: tab.badgeHost.isEmpty ? tab.displayTitle : tab.badgeHost),
                    title: tab.displayTitle,
                    subtitle: [tab.badgeHost.isEmpty ? nil : tab.badgeHost, tab.spaceIndex == currentSpace ? nil : spaces[min(tab.spaceIndex, spaces.count - 1)].name].compactMap { $0 }.joined(separator: " · "),
                    trailing: tab.id == activeTabID ? "actif" : "Basculer",
                    perform: { [weak self, weak tab] _ in if let tab { self?.selectTab(tab) } }
                )
            }))
        }

        let favorites = ((try? bookmarkRepo.all()) ?? []).filter { matches($0.title, $0.url) }
        if filter == .all || filter == .bookmarks {
            sections.append(PaletteSection(title: "Favoris", items: favorites.prefix(filter == .all ? 4 : 30).map { bookmark in
                PaletteItem(
                    icon: .site(host: URL(string: bookmark.url)?.host ?? bookmark.url),
                    title: bookmark.title.isEmpty || bookmark.title == bookmark.url
                        ? (URL(string: bookmark.url)?.host ?? bookmark.url) : bookmark.title,
                    subtitle: bookmark.url,
                    trailing: nil,
                    perform: { [weak self] inNewTab in self?.openFromPalette(bookmark.url, inNewTab: inNewTab) }
                )
            }))
        }

        if filter == .all || filter == .history {
            let favoriteURLs = Set(favorites.map(\.url))
            let entries: [(url: String, title: String, date: Date?)]
            if q.isEmpty {
                entries = ((try? historyRepo.recent(limit: 6)) ?? []).map { ($0.url, $0.title, $0.lastVisitedAt) }
            } else {
                entries = ((try? SuggestionProvider().suggestions(for: q, limit: 8)) ?? []).map { ($0.url, $0.title, nil) }
            }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            let shown = entries.filter { filter == .history || !favoriteURLs.contains($0.url) }.prefix(filter == .all ? 5 : 30)
            sections.append(PaletteSection(title: "Historique", items: shown.map { entry in
                PaletteItem(
                    icon: .symbol("clock"),
                    title: entry.title.isEmpty ? entry.url : entry.title,
                    subtitle: URL(string: entry.url)?.host,
                    trailing: entry.date.map { formatter.localizedString(for: $0, relativeTo: Date()) },
                    perform: { [weak self] inNewTab in self?.openFromPalette(entry.url, inNewTab: inNewTab) }
                )
            }))
        }

        if filter == .all || filter == .actions {
            let spaceItems = spaces.enumerated().filter { matches($0.element.name, "espace") && $0.offset != currentSpace }.map { index, style in
                PaletteItem(icon: .symbol(style.icon.symbol), title: "Aller à « \(style.name) »", subtitle: nil,
                            trailing: "⌃\(index + 1)", perform: { [weak self] _ in self?.selectSpace(index) })
            }
            if !spaceItems.isEmpty { sections.append(PaletteSection(title: "Espaces", items: Array(spaceItems.prefix(filter == .all && q.isEmpty ? 3 : 12)))) }
            let actions: [(String, String, @MainActor (BrowserWindowController) -> Void)] = [
                ("Écran partagé", "rectangle.split.2x1", { $0.toggleSplit() }),
                ("Ajouter à la liste de lecture", "text.book.closed", { if let tab = $0.activeTab { $0.addToReadingList(tab) } }),
                ("Afficher l'historique", "clock", { $0.openHistoryPanel() }),
                ("Personnaliser l'apparence", "paintbrush", { $0.openCustomize() }),
                ("Vue d'ensemble des espaces", "square.grid.2x2", { $0.openOverview() }),
                ("Mettre l'onglet en veille", "moon", { $0.sleepActiveTab() }),
                ("Nouvel onglet vide", "plus", { $0.newTab(urlString: nil, isPrivate: SettingsStore.shared.privateByDefault) }),
                ("Nouvel onglet privé", "lock.shield", { $0.newPrivateTabAction() }),
                ("Rouvrir l'onglet fermé", "arrow.uturn.backward", { $0.reopenClosedTab() }),
                ("Aller à l'espace suivant", "square.stack", { $0.selectNextSpace() }),
                ("Recharger la page", "arrow.clockwise", { $0.reloadAction() }),
                ("Ajouter ou retirer des favoris", "star", { if let tab = $0.activeTab { $0.toggleBookmark(for: tab) } }),
                ("Rechercher dans la page", "text.magnifyingglass", { $0.findInPage() }),
                ("Afficher ou masquer la barre latérale", "sidebar.left", { $0.toggleSidebar() }),
                ("Fermer l'onglet", "xmark", { $0.closeActiveTabAction() }),
                ("Réglages", "gearshape", { $0.openSettings() }),
            ]
            let found = actions.filter { matches($0.0) }
            sections.append(PaletteSection(title: "Actions", items: found.prefix(filter == .all && q.isEmpty ? 4 : 12).map { action in
                PaletteItem(icon: .symbol(action.1), title: action.0, subtitle: nil, trailing: nil,
                            perform: { [weak self] _ in if let self { action.2(self) } })
            }))
        }
        return sections
    }

    /// Whether typed text should be opened as an address rather than searched.
    static func looksLikeAddress(_ text: String) -> Bool {
        if text.contains(" ") { return false }
        if text.contains("://") { return true }
        if text.hasPrefix("localhost") { return true }
        if text.range(of: #"^[\w.-]+:\d{2,5}(/.*)?$"#, options: .regularExpression) != nil { return true }
        return text.contains(".")
    }

    private func buildFindBar(in contentView: NSView) {
        findField.translatesAutoresizingMaskIntoConstraints = false
        findField.placeholderString = "Rechercher dans la page"
        findField.setAccessibilityLabel("Rechercher dans la page")
        findField.isBordered = false
        findField.focusRingType = .none
        findField.target = self
        findField.action = #selector(findNext)
        findField.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let prevButton = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Précédent")!, target: self, action: #selector(findPrevious))
        let nextButton = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Suivant")!, target: self, action: #selector(findNext))
        let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Fermer")!, target: self, action: #selector(closeFindBar))
        [prevButton, nextButton, closeButton].forEach {
            $0.isBordered = false
            $0.bezelStyle = .circular
        }

        findBar.orientation = .horizontal
        findBar.spacing = 4
        findBar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        [findField, prevButton, nextButton, closeButton].forEach { findBar.addArrangedSubview($0) }

        let findCard = makeFloatingCard(findBar, cornerRadius: 10)
        findCard.isHidden = true
        self.findBarContainer = findCard

        contentView.addSubview(findCard)
        NSLayoutConstraint.activate([
            findCard.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 8),
            findCard.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -16),
        ])
    }

    // MARK: - Tab lifecycle

    private func makeConfiguration(isPrivate: Bool) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = isPrivate ? privateProcessPool : processPool
        config.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.applicationNameForUserAgent = UserAgent.applicationName   // announce as Safari: sites serve their current pages
        WebKitTuning.applyFeatures(to: config.preferences)
        // Off by default in WKWebView: without it, the fullscreen button on
        // videos (YouTube, etc.) and the Fullscreen API do nothing.
        config.preferences.isElementFullscreenEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = SettingsStore.shared.autoplayMediaAllowed ? [] : .all
        if SettingsStore.shared.adBlockEnabled {
            contentBlocker.ruleLists.forEach { config.userContentController.add($0) }
        }
        if SettingsStore.shared.fingerprintProtection {
            config.userContentController.addUserScript(FingerprintProtection.makeUserScript(sessionSeed: fingerprintSeed))
        }
        config.userContentController.addUserScript(CredentialScript.makeUserScript())
        if SettingsStore.shared.lightLongPages {
            config.userContentController.addUserScript(LongPageScript.makeUserScript())
        }
        config.userContentController.add(credentialHandler, name: CredentialScript.handlerName)
        config.setURLSchemeHandler(oreeSchemeHandler, forURLScheme: "oree")
        // Extensions run in normal tabs only, never in private ones.
        if !isPrivate { config.webExtensionController = extensionManager.controller }
        return config
    }

    private func attachTab(_ tab: Tab) {
        tab.owner = self
        tab.webView?.navigationDelegate = self
        tab.webView?.uiDelegate = self
        // Weak: Tab owns its button, so a strong capture here is a retain cycle that
        // keeps every closed tab (and its playing video) alive forever.
        tab.tabButton.onSelect = { [weak self, weak tab] in if let tab { self?.selectTab(tab) } }
        tab.tabButton.onClose = { [weak self, weak tab] in if let tab { self?.closeTab(tab) } }
        tab.tabButton.onReorder = { [weak self, weak tab] steps in
            guard let self, let tab else { return }
            self.moveTab(tab, by: steps)
        }
        tab.tabButton.contextMenuProvider = { [weak self, weak tab] in
            guard let self, let tab else { return nil }
            return self.makeTabMenu(for: tab)
        }
        tab.tabButton.onToggleMute = { [weak self, weak tab] in
            tab?.toggleMute()
            self?.refreshAudioIndicators()
        }
        tab.tabButton.setTitle(tab.displayTitle, host: tab.badgeHost)

        tabs.append(tab)
        contentContainer.addSubview(tab.contentSlot, positioned: .below, relativeTo: loadingBar)
        tab.onTitleChange = { [weak self, weak tab] in
            guard let tab else { return }
            tab.tabButton.setTitle(tab.displayTitle, host: tab.badgeHost)
            if self?.effectiveSidebarMode == .compact { self?.updateTabCount() }
            self?.extensionManager.tabChanged(tab, .title)
        }
        tab.onURLChange = { [weak self, weak tab] in
            guard let self, let tab else { return }
            tab.tabButton.setTitle(tab.displayTitle, host: tab.badgeHost)
            if tab.id == self.activeTabID { self.syncToolbar(for: tab) }
        }
        tab.onSleepChange = { [weak self, weak tab] _ in
            guard let self, let tab else { return }
            tab.tabButton.setSleeping(tab.isSuspended)
            self.updateTabCount()
        }
        tab.tabButton.setSleeping(tab.isSuspended)
        tab.onFreezeChange = { [weak self, weak tab] _ in
            guard let self, let tab else { return }
            tab.tabButton.setFrozen(tab.isFrozen)
            self.updateTabCount()
        }
        tab.tabButton.onHoverDwell = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.prewake(tab)
        }
        tab.onProgress = { [weak self, weak tab] progress, isLoading in
            guard let self, let tab else { return }
            let hue = self.spaces[min(tab.spaceIndex, self.spaces.count - 1)].hue
            tab.tabButton.setLoading(isLoading, hue: hue)
            guard tab.id == self.activeTabID else { return }
            self.loadingBar.update(progress: progress, isLoading: isLoading)
        }
        tab.slotTop = tab.contentSlot.topAnchor.constraint(equalTo: contentContainer.topAnchor)
        tab.slotLeading = tab.contentSlot.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor)
        tab.slotTrailing = tab.contentSlot.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor)
        tab.slotBottom = tab.contentSlot.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        NSLayoutConstraint.activate([tab.slotTop!, tab.slotLeading!, tab.slotTrailing!, tab.slotBottom!])
        tab.contentSlot.isHidden = true
        rebuildTabList()
        if tab.spaceIndex == currentSpace { tab.tabButton.animateIn() }
        extensionManager.tabOpened(tab)
    }

    /// Reloading after `webViewWebContentProcessDidTerminate` respawns a
    /// fresh WebContent process for the same `WKWebView` instance — the tab,
    /// its back-forward history and the rest of the app are untouched.
    private func recoverFromCrash(_ tab: Tab) {
        tab.interstitial.hide()
        if let url = tab.webView?.url {
            tab.webView?.load(URLRequest(url: url))
        } else {
            tab.webView?.reload()
        }
    }

    @discardableResult
    func newTab(urlString: String?, isPrivate: Bool) -> Tab {
        let config = makeConfiguration(isPrivate: isPrivate)
        LaunchTrace.mark("newTab: configuration made")
        let tab = Tab(configuration: config, isPrivate: isPrivate)
        LaunchTrace.mark("newTab: tab + web view created")
        tab.spaceIndex = currentSpace
        attachTab(tab)
        LaunchTrace.mark("newTab: attached")
        let homepage = SettingsStore.shared.customHomepageURL
        if let urlString {
            load(urlString: urlString, in: tab)
        } else if !homepage.isEmpty {
            load(urlString: homepage, in: tab)
        } else {
            let input = homeInput(for: tab)
            LaunchTrace.mark("newTab: home data read")
            let html = StartPage.render(input)
            LaunchTrace.mark("newTab: home html rendered")
            tab.webView?.loadHTMLString(html, baseURL: StartPage.baseURL)
        }
        selectTab(tab)
        LaunchTrace.mark("newTab: selected")
        saveSession()
        return tab
    }

    /// Everything the home page shows, for a tab in the current space.
    private func homeInput(for tab: Tab) -> HomeInput {
        let recent = (tab.isPrivate || !SettingsStore.shared.startPageShowsRecent) ? [] : ((try? historyRepo.recent(limit: 6)) ?? [])
        let style = spaces[min(tab.spaceIndex, spaces.count - 1)]
        let chips = spaces.enumerated().map { index, space in
            HomeInput.SpaceChip(index: index, name: space.name, hue: space.hue, icon: space.icon,
                                tabCount: tabs.filter { $0.spaceIndex == index }.count)
        }
        return HomeInput(hue: style.hue,
                         favorites: (try? bookmarkRepo.all(forSpace: tab.spaceIndex)) ?? [],
                         recent: recent, spaces: chips)
    }

    /// Links of the home page that ask the app to do something (oree-action://…).
    private func handleHomeAction(_ url: URL) {
        switch url.host {
        case "space": if let index = Int(url.lastPathComponent) { selectSpace(index) }
        case "customize": openSettings()
        default: break
        }
    }

    func selectTab(_ tab: Tab) {
        // Picking a tab that isn't one of the two sides leaves the split screen.
        if let pair = splitPair, tab.id != pair.left, tab.id != pair.right { endSplit(keeping: tab.id) }
        if tab.spaceIndex != currentSpace { setCurrentSpace(tab.spaceIndex, animated: true) }
        lastActiveTabInSpace[tab.spaceIndex] = tab.id
        if let gid = tab.groupID, let gi = groups.firstIndex(where: { $0.id == gid }), groups[gi].collapsed {
            groups[gi].collapsed = false
            rebuildTabList()
        }
        let previouslyActive = activeTab
        if let previous = activeTab, previous.id != tab.id {
            previous.tabButton.isActive = false
            previous.contentSlot.isHidden = !splitContains(previous.id)
            previous.lastActiveDate = Date()
            // Snapshot now, while the page is exactly as the user saw it — sleeping later then costs nothing.
            Task { await previous.captureSnapshot() }
        }
        let switching = activeTabID != nil && activeTabID != tab.id
        activeTabID = tab.id
        tab.contentSlot.isHidden = false
        tab.tabButton.isActive = true
        if SettingsStore.shared.tabLayout == .horizontal, tab.tabButton.superview === tabStrip.tabsStack { tabStrip.reveal(tab.tabButton) }
        if switching {
            tab.contentSlot.alphaValue = 0
            Motion.animate(Motion.quick) { tab.contentSlot.animator().alphaValue = 1 }
        }

        ensureAwake(tab)

        syncToolbar(for: tab)
        refreshSplitHeaders()
        updateTabCount()
        if previouslyActive?.id != tab.id { extensionManager.tabActivated(tab, previous: previouslyActive) }
        refreshExtensionToolbar()
        loadingBar.update(progress: tab.webView?.estimatedProgress ?? 0, isLoading: tab.webView?.isLoading ?? false)
        if let webView = tab.webView {
            window?.makeFirstResponder(webView)
        }
    }

    func closeTab(_ tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if let pair = splitPair, tab.id == pair.left || tab.id == pair.right {
            endSplit(keeping: tab.id == pair.left ? pair.right : pair.left)
        }
        extensionManager.tabClosed(tab)
        if !tab.isPrivate, let url = tab.currentURL {
            closedTabs.append((url, tab.currentInteractionState, tab.displayTitle, tab.spaceIndex))
            if closedTabs.count > 20 { closedTabs.removeFirst() }
        }
        tab.contentSlot.removeFromSuperview()
        tab.tearDown()
        tabs.remove(at: idx)
        updateTabCount()
        let button = tab.tabButton
        button.animateOut { [weak self] in
            guard let self else { return }
            Motion.animate(Motion.standard) {
                self.rebuildTabList()
                self.tabBarStack.superview?.layoutSubtreeIfNeeded()
            }
            button.removeFromSuperview()
        }
        saveSession()

        if tabs.isEmpty {
            window?.close()
            return
        }
        if activeTabID == tab.id {
            // The closest tab in the same space; if that space is now empty, open a fresh one in it.
            if let next = TabSelection.neighbor(afterRemovingIndex: idx, spaces: tabs.map(\.spaceIndex), space: tab.spaceIndex) {
                selectTab(tabs[next])
            } else {
                newTab(urlString: nil, isPrivate: SettingsStore.shared.privateByDefault)
            }
        }
    }

    /// Moves the active tab one slot up/down in both the model array and the
    /// sidebar's stack view — the "réordonner" requirement. Drag-and-drop in
    /// the sidebar is a natural follow-up; this keyboard path is the simplest
    /// thing that actually lets you reorder tabs today.
    private func moveActiveTab(by offset: Int) {
        guard let tab = activeTab else { return }
        moveTab(tab, by: offset)
    }

    /// Moves `tab` by `offset` rows (clamped), in both the model and the sidebar.
    func moveTab(_ tab: Tab, by offset: Int) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }),
              let newIndex = TabSelection.destinationIndex(of: idx, offset: offset, spaces: tabs.map(\.spaceIndex)) else { return }

        tabs.remove(at: idx)
        tabs.insert(tab, at: newIndex)
        Motion.animate(Motion.standard) {
            rebuildTabList()
            tabBarStack.superview?.layoutSubtreeIfNeeded()
            tabStrip.layoutSubtreeIfNeeded()
        }
        saveSession()
    }

    // MARK: - Spaces

    private func visibleTabs() -> [Tab] { tabs.filter { $0.spaceIndex == currentSpace } }

    /// Header of the tab column: "N onglets · N en veille" for the current space.
    private func updateTabCount() {
        let mine = visibleTabs()
        let sleeping = mine.filter(\.isSuspended).count
        let frozen = mine.filter(\.isFrozen).count
        let count = mine.count
        spaceMetaLabel.stringValue = "\(count) onglet\(count > 1 ? "s" : "") · \(sleeping) en veille" + (frozen > 0 ? " · \(frozen) en pause" : "")
        sleepMetaLabel.stringValue = sleeping > 0 ? "\(sleeping) en veille" : ""
        spaceRail.setTabs(mine.map { tab in
            (tab.displayTitle, tab.badgeHost, tab.id == activeTabID, tab.isSuspended,
             { [weak self, weak tab] in if let tab { self?.selectTab(tab) } })
        })
    }

    /// Brings the sidebar in line with `currentSpace`: rail, header, lisière, which tab rows are shown.
    private func refreshSpaceUI(animated: Bool) {
        let style = currentSpaceStyle
        spaceRail.configure(spaces: spaces, selected: currentSpace, compact: effectiveSidebarMode == .compact)
        if effectiveSidebarMode == .floating { refreshHoverSpaceRow() }          // keep the icon row's selection in sync
        spaceNameLabel.stringValue = style.name
        loadingBar.color = Theme.hue(style.hue)
        rebuildTabList()
        if animated { visibleTabs().forEach { $0.tabButton.animateIn() } }
        refreshPinnedIcons()
        if activePanel == .favorites { refreshPanel() }
    }

    // MARK: - Tab list and groups

    /// Lays out the tab column for the current space: groups (collapsible), then "Pages libres".
    private func rebuildTabList() {
        let horizontal = SettingsStore.shared.tabLayout == .horizontal
        let items = tabs.map { TabListLayout.Item(id: $0.id, spaceIndex: $0.spaceIndex, groupID: $0.groupID) }
        let rows = TabListLayout.rows(tabs: items, groups: groups, space: currentSpace)
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        for stack in [tabBarStack, tabStrip.tabsStack] {
            stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        }
        let container: NSStackView = horizontal ? tabStrip.tabsStack : tabBarStack
        for row in rows {
            switch row {
            case .groupHeader(let id):
                guard let group = groups.first(where: { $0.id == id }) else { continue }
                if horizontal {
                    container.addArrangedSubview(makeStripGroupChip(group.name, hue: currentSpaceStyle.hue))
                    continue
                }
                let members = tabs.filter { $0.groupID == id }.count
                let header = GroupHeaderView(name: group.name, tabCount: members, collapsed: group.collapsed)
                header.onToggle = { [weak self] in self?.toggleGroup(id) }
                header.contextMenuProvider = { [weak self] in self?.makeGroupMenu(for: id) }
                container.addArrangedSubview(header)
            case .looseHeader:
                if !horizontal { container.addArrangedSubview(makeSectionLabel("Pages libres")) }
            case .tab(let id, let indented):
                guard let tab = byID[id] else { continue }
                tab.tabButton.isHidden = false
                tab.tabButton.setHorizontal(horizontal)
                tab.tabButton.setIndented(indented && !horizontal)
                container.addArrangedSubview(tab.tabButton)
            }
        }
        if horizontal {
            tabStrip.spaceChip.configure(currentSpaceStyle)
            tabStrip.tabsChanged()
            if let active = activeTab, active.tabButton.superview === tabStrip.tabsStack { tabStrip.reveal(active.tabButton) }
        }
        updateTabCount()
    }

    private func toggleGroup(_ id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].collapsed.toggle()
        Motion.animate(Motion.standard) { rebuildTabList(); tabBarStack.superview?.layoutSubtreeIfNeeded() }
        saveSession()
    }

    private func makeGroupMenu(for id: UUID) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Renommer le groupe…") { [weak self] in self?.renameGroup(id) })
        menu.addItem(ClosureMenuItem(title: "Dissoudre le groupe") { [weak self] in self?.dissolveGroup(id) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Fermer les onglets du groupe") { [weak self] in
            guard let self else { return }
            for tab in self.tabs where tab.groupID == id { self.closeTab(tab) }
            self.dissolveGroup(id)
        })
        return menu
    }

    private func promptForText(title: String, button: String, initial: String, completion: @escaping @MainActor (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Annuler")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            MainActor.assumeIsolated { completion(String(text.prefix(30))) }
        }
    }

    private func renameGroup(_ id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        promptForText(title: "Renommer le groupe", button: "Renommer", initial: groups[index].name) { [weak self] name in
            guard let self, let i = self.groups.firstIndex(where: { $0.id == id }) else { return }
            self.groups[i].name = name
            self.rebuildTabList()
            self.saveSession()
        }
    }

    private func dissolveGroup(_ id: UUID) {
        for tab in tabs where tab.groupID == id { tab.groupID = nil }
        groups.removeAll { $0.id == id }
        rebuildTabList()
        saveSession()
    }

    /// Creates a group in the tab's space (asking for a name) and puts the tab in it.
    func newGroup(with tab: Tab) {
        promptForText(title: "Nouveau groupe", button: "Créer", initial: "") { [weak self, weak tab] name in
            guard let self, let tab else { return }
            let group = TabGroup(name: name, spaceIndex: tab.spaceIndex)
            self.groups.append(group)
            tab.groupID = group.id
            self.rebuildTabList()
            self.saveSession()
        }
    }

    func assign(_ tab: Tab, to groupID: UUID?) {
        tab.groupID = groupID
        if let groupID, let i = groups.firstIndex(where: { $0.id == groupID }), groups[i].collapsed { groups[i].collapsed = false }
        rebuildTabList()
        saveSession()
    }

    private func setCurrentSpace(_ index: Int, animated: Bool) {
        guard index != currentSpace, spaces.indices.contains(index) else { return }
        let forward = index > currentSpace
        currentSpace = index
        UserDefaults.standard.set(index, forKey: Self.activeSpaceKey)
        refreshSpaceUI(animated: animated)
        if animated {
            // The new space's tabs drift in from the side the space sits on; names and colours cross-fade.
            let horizontal = SettingsStore.shared.tabLayout == .horizontal
            Motion.enter(horizontal ? tabStrip.tabsStack : tabBarStack, fromX: horizontal ? (forward ? 24 : -24) : 0,
                         fromY: horizontal ? 0 : (forward ? -14 : 14))
            [spaceNameLabel, spaceMetaLabel, tabStrip.spaceChip].forEach { Motion.crossfade($0) }
        }
    }

    /// User picked a space: show its tabs and go to the one you were last on there.
    func selectSpace(_ index: Int) {
        guard index != currentSpace, spaces.indices.contains(index) else { return }
        setCurrentSpace(index, animated: true)
        let remembered = lastActiveTabInSpace[index].flatMap { id in tabs.first { $0.id == id && $0.spaceIndex == index } }
        if let target = remembered ?? visibleTabs().first {
            selectTab(target)
        } else {
            newTab(urlString: nil, isPrivate: SettingsStore.shared.privateByDefault)   // empty space: start page
        }
        saveSession()
    }

    @objc func selectNextSpace() { selectSpace((currentSpace + 1) % spaces.count) }

    /// ⌃1…⌃3
    @objc func selectSpaceByNumber(_ sender: NSMenuItem) { selectSpace(sender.tag - 1) }

    func moveTab(_ tab: Tab, toSpace index: Int) {
        guard index != tab.spaceIndex, spaces.indices.contains(index) else { return }
        if splitContains(tab.id) { endSplit(keeping: nil) }
        let wasActive = tab.id == activeTabID
        tab.spaceIndex = index
        tab.groupID = nil
        refreshSpaceUI(animated: true)
        if wasActive {
            if let other = visibleTabs().first(where: { $0.id != tab.id }) {
                selectTab(other)
            } else {
                newTab(urlString: nil, isPrivate: SettingsStore.shared.privateByDefault)
            }
        }
        saveSession()
    }

    /// Adds a space with the next unused hue (the full editor — name, icon, hue — comes with the overview screen).
    func addSpace(select: Bool = true) {
        let used = Set(spaces.map(\.hue))
        let hue = OreeTokens.Hue.allCases.first { !used.contains($0) } ?? .graphite
        let icons = SpaceIcon.allCases
        spaces.append(SpaceStyle(name: "Espace \(spaces.count + 1)", hue: hue, icon: icons[spaces.count % icons.count]))
        if select { selectSpace(spaces.count - 1) }
        refreshSpaceUI(animated: false)
    }

    func renameSpace(_ index: Int) {
        guard let window, spaces.indices.contains(index) else { return }
        let alert = NSAlert()
        alert.messageText = "Renommer l'espace"
        alert.addButton(withTitle: "Renommer")
        alert.addButton(withTitle: "Annuler")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = spaces[index].name
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            MainActor.assumeIsolated {
                self.spaces[index].name = String(name.prefix(14))
                self.refreshSpaceUI(animated: false)
            }
        }
    }

    // MARK: - Memory budget

    private func startMemoryBudgetTimer() {
        memoryBudgetTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.enforceMemoryBudget() }
        }
    }

    /// Fraction of the budget the last pass found in use; pre-waking is skipped while over budget.
    private var isOverBudget = false

    private func memoryBudgetBytes() -> UInt64? {
        let setting = SettingsStore.shared.memoryBudgetMB
        guard setting >= 0 else { return nil }
        return setting == 0 ? MemoryBudget.automaticBudgetBytes() : UInt64(setting) * 1_048_576
    }

    /// One pass of the tab lifecycle, every 20 s (awake → frozen → asleep, see `TabLifecyclePolicy`):
    ///  1. hidden tabs: after a minute out of sight, clean their JavaScript memory (once per absence);
    ///  2. over budget: first clean (cheap, nothing is lost), and only if that isn't enough, apply the plan;
    ///  3. the plan freezes tabs hidden for a while and sleeps the ones hidden very long or, when over
    ///     budget, the best-scoring ones down to 80 % of the budget.
    private func enforceMemoryBudget() async {
        // Safety net: a paused page must never be the one on screen.
        for tab in tabs where tab.isFrozen && isOnScreen(tab) { tab.thaw() }
        await cleanHiddenTabsIfDue()

        var reading = measureTabMemory()
        recordSiteSamples(reading)

        let budget = memoryBudgetBytes() ?? UInt64.max
        isOverBudget = reading.total > budget

        if isOverBudget, releaseJavaScriptMemory(reason: "over budget") {
            try? await Task.sleep(for: .seconds(4))
            reading = measureTabMemory()
            isOverBudget = reading.total > budget
        }
        let plan = await lifecyclePlan(reading: reading, budget: budget, timing: lifecycleTiming())
        let slept = await apply(plan)
        if slept > 0 {
            Log.tabs.notice("Tab lifecycle: \(reading.total / 1_048_576) MB used, froze \(plan.freeze.count), slept \(slept)")
        }
    }

    private func lifecycleTiming() -> TabLifecyclePolicy.Timing {
        var sleepAfter = TimeInterval(SettingsStore.shared.autoSuspendMinutes * 60)
        // After a recent memory warning, be much less patient.
        if sleepAfter > 0, let last = lastMemoryPressure, Date().timeIntervalSince(last) < 600 { sleepAfter = min(sleepAfter, 180) }
        return .init(freezeAfter: TimeInterval(SettingsStore.shared.freezeAfterSeconds), sleepAfter: sleepAfter)
    }

    /// Why a tab may or may not be touched: on screen, playing sound, using camera/mic, a messaging
    /// or "never sleep" site → left alone; unsaved input → frozen but never torn down.
    private func lifecycleExemption(of tab: Tab) async -> TabLifecyclePolicy.Exemption {
        if isOnScreen(tab) || tab.isCapturingMedia || tab.isInFullscreen || tab.audioState == .playing { return .full }
        if SleepExemptions.isExempt(host: tab.currentURL?.host, userHosts: SettingsStore.shared.neverSleepHosts) { return .full }
        if await tab.isPlayingMedia() { return .full }
        return tab.isDirty ? .noSleep : .none
    }

    private func lifecyclePlan(reading: MemoryReading, budget: UInt64, timing: TabLifecyclePolicy.Timing) async -> TabLifecyclePolicy.Plan {
        let tabsPerProcess = Dictionary(grouping: reading.processOfTab.values, by: { $0 }).mapValues(\.count)
        let now = Date()
        var entries: [TabLifecyclePolicy.Entry] = []
        for tab in tabs where !tab.isSuspended && tab.webView != nil {
            guard let pid = reading.processOfTab[tab.id], let bytes = reading.bytesByProcess[pid] else { continue }
            var limit = timing.sleepAfter
            if limit > 0 {
                // A space you've switched away from is out of sight: its tabs sleep after 2 minutes at most.
                if tab.spaceIndex != currentSpace { limit = min(limit, 120) }
                limit = SiteMemoryPolicy.idleLimit(base: limit, profile: siteProfile(forHost: SiteMemoryPolicy.normalizedHost(tab.currentURL)))
            }
            entries.append(.init(id: tab.id, bytes: bytes / UInt64(max(tabsPerProcess[pid] ?? 1, 1)),
                                 idleSeconds: now.timeIntervalSince(tab.lastActiveDate),
                                 state: tab.isFrozen ? .frozen : .awake,
                                 exemption: await lifecycleExemption(of: tab),
                                 keepWeight: tab.spaceIndex == currentSpace ? 0.5 : 1,
                                 sleepAfter: limit))
        }
        return TabLifecyclePolicy.plan(entries: entries, budgetBytes: budget, timing: timing)
    }

    /// Carries out a plan; returns how many tabs were put to sleep.
    @discardableResult
    private func apply(_ plan: TabLifecyclePolicy.Plan) async -> Int {
        for id in plan.freeze { tabs.first { $0.id == id }?.freeze() }
        var slept = 0
        for id in plan.sleep {
            guard let tab = tabs.first(where: { $0.id == id }), !isOnScreen(tab) else { continue }
            await tab.suspend()
            slept += 1
        }
        return slept
    }

    /// Puts the best-scoring hidden tabs to sleep until the total should fit `target` (the active tab,
    /// sound/camera tabs and tabs with unsaved input are never torn down). Returns how many slept.
    private func sleepTabs(toReach target: UInt64, reading: MemoryReading, minimumIdle: Double) async -> Int {
        let timing = TabLifecyclePolicy.Timing(freezeAfter: 0, sleepAfter: 0, minimumIdle: minimumIdle, hysteresis: 1)
        var plan = await lifecyclePlan(reading: reading, budget: target, timing: timing)
        plan.freeze = []
        return await apply(plan)
    }

    // MARK: Learned site profiles

    private func siteProfile(forHost host: String?) -> SiteProfile? {
        guard SettingsStore.shared.learnSiteMemory, let host else { return nil }
        if let cached = siteProfileCache[host] { return cached }
        let profile = try? siteMemoryRepo.profile(host: host)
        siteProfileCache[host] = .some(profile)
        return profile
    }

    /// Every pass, remember how much each open (non-private, settled) site is using.
    private func recordSiteSamples(_ reading: MemoryReading) {
        guard SettingsStore.shared.learnSiteMemory else { return }
        let tabsPerProcess = Dictionary(grouping: reading.processOfTab.values, by: { $0 }).mapValues(\.count)
        for tab in tabs where !tab.isPrivate && tab.webView?.isLoading == false {
            guard let host = SiteMemoryPolicy.normalizedHost(tab.currentURL),
                  let pid = reading.processOfTab[tab.id], let bytes = reading.bytesByProcess[pid] else { continue }
            let megabytes = Double(bytes) / 1_048_576 / Double(max(tabsPerProcess[pid] ?? 1, 1))
            try? siteMemoryRepo.record(host: host, megabytes: megabytes)
            siteProfileCache[host] = nil
            if SiteMemoryPolicy.isHeavy(siteProfile(forHost: host)), let profile = siteProfile(forHost: host) {
                tab.tabButton.toolTip = "Site gourmand : ~\(Int(profile.averageMB)) Mo en moyenne"
            }
        }
    }

    /// Opening a site known to be heavy: free up room *before* it loads, so the Mac doesn't start swapping.
    private func makeRoom(forNavigationTo url: URL, in tab: Tab) async {
        guard SettingsStore.shared.learnSiteMemory, SettingsStore.shared.memoryBudgetMB >= 0,
              let host = SiteMemoryPolicy.normalizedHost(url),
              case let predicted = SiteMemoryPolicy.predictedBytes(for: siteProfile(forHost: host)), predicted > 0 else { return }
        let setting = SettingsStore.shared.memoryBudgetMB
        let budget = setting == 0 ? MemoryBudget.automaticBudgetBytes() : UInt64(setting) * 1_048_576
        let reading = measureTabMemory()
        // The page being replaced stops counting once the new one loads.
        let currentOfThisTab = tab.webProcessID.flatMap { reading.bytesByProcess[$0] } ?? 0
        let projected = reading.total - min(reading.total, currentOfThisTab) + predicted
        guard projected > budget else { return }
        let slept = await sleepTabs(toReach: budget > predicted ? budget - predicted + currentOfThisTab : currentOfThisTab, reading: reading, minimumIdle: 5)
        if slept > 0 {
            Log.tabs.notice("Making room for \(host, privacy: .public) (~\(predicted / 1_048_576) MB expected): put \(slept) tab(s) to sleep")
        }
    }

    private struct MemoryReading {
        var total: UInt64
        var bytesByProcess: [Int32: UInt64]
        var processOfTab: [UUID: Int32]
    }

    private func measureTabMemory() -> MemoryReading {
        var bytesByProcess: [Int32: UInt64] = [:]
        var processOfTab: [UUID: Int32] = [:]
        for tab in tabs where tab.webView != nil {
            guard let pid = tab.webProcessID, let bytes = MemoryBudget.footprint(ofProcess: pid) else { continue }
            bytesByProcess[pid] = bytes
            processOfTab[tab.id] = pid
        }
        return MemoryReading(total: bytesByProcess.values.reduce(0, +), bytesByProcess: bytesByProcess, processOfTab: processOfTab)
    }

    /// JavaScript garbage collection plus WebKit's in-memory caches. At most once a minute:
    /// the collection runs in every web process, so it must not become a constant background cost.
    @discardableResult
    private func releaseJavaScriptMemory(reason: String) -> Bool {
        guard Date().timeIntervalSince(lastGarbageCollection) > 60,
              let pool = tabs.compactMap({ $0.webView?.configuration.processPool }).first,
              WebKitTuning.collectJavaScriptGarbage(in: pool) else { return false }
        lastGarbageCollection = Date()
        WebKitTuning.purgeMemoryCaches()
        Log.tabs.notice("Memory cleanup (\(reason, privacy: .public))")
        return true
    }

    /// A tab that has been out of sight for a minute gets its JavaScript memory cleaned, once per absence.
    private func cleanHiddenTabsIfDue() async {
        guard SettingsStore.shared.backgroundCleanup else { return }
        let now = Date()
        let due = tabs.filter { tab in
            guard tab.webView != nil, !isOnScreen(tab), now.timeIntervalSince(tab.lastActiveDate) >= 60 else { return false }
            return tab.lastCleanup.map { $0 < tab.lastActiveDate } ?? true
        }
        guard !due.isEmpty, releaseJavaScriptMemory(reason: "\(due.count) hidden tab(s)") else { return }
        for tab in due { tab.lastCleanup = now }
    }

    // MARK: - Audio indicators

    private func startAudioTimer() {
        audioTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAudioIndicators() }
        }
    }

    private func refreshAudioIndicators() {
        for tab in tabs where tab.webView != nil { tab.tabButton.setAudio(tab.audioState) }
    }

    // MARK: - Tab menu, reopen, shortcuts

    private func makeTabMenu(for tab: Tab) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, enabled: Bool = true, _ action: @escaping @MainActor () -> Void) {
            let item = ClosureMenuItem(title: title, action: action)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add("Recharger", enabled: tab.webView != nil) { tab.webView?.reload() }
        add("Dupliquer") { [weak self] in
            if let url = tab.currentURL { self?.newTab(urlString: url.absoluteString, isPrivate: tab.isPrivate) }
        }
        let isFavorite = tab.currentURL.flatMap { try? bookmarkRepo.contains(url: $0.absoluteString) } ?? false
        add(isFavorite ? "Retirer des favoris" : "Ajouter aux favoris", enabled: tab.currentURL != nil) { [weak self] in
            self?.toggleBookmark(for: tab)
        }
        add("Ajouter à la liste de lecture", enabled: tab.currentURL != nil) { [weak self] in self?.addToReadingList(tab) }
        add("Copier le lien", enabled: tab.currentURL != nil) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.currentURL?.absoluteString ?? "", forType: .string)
        }
        let groupItem = NSMenuItem(title: "Ajouter au groupe", action: nil, keyEquivalent: "")
        let groupMenu = NSMenu()
        for group in groups where group.spaceIndex == tab.spaceIndex && group.id != tab.groupID {
            groupMenu.addItem(ClosureMenuItem(title: group.name) { [weak self] in self?.assign(tab, to: group.id) })
        }
        if !groupMenu.items.isEmpty { groupMenu.addItem(.separator()) }
        groupMenu.addItem(ClosureMenuItem(title: "Nouveau groupe…") { [weak self] in self?.newGroup(with: tab) })
        groupItem.submenu = groupMenu
        menu.addItem(groupItem)
        if tab.groupID != nil { add("Retirer du groupe") { [weak self] in self?.assign(tab, to: nil) } }
        add("Ouvrir côte à côte", enabled: tab.id != activeTabID && activeTab != nil && !(activeTab?.isPrivate ?? true) == !tab.isPrivate) { [weak self] in
            guard let self, let active = self.activeTab else { return }
            self.beginSplit(left: active, right: tab)
        }
        let host = tab.currentURL?.host?.lowercased().replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
        if let host, !host.isEmpty {
            let never = SettingsStore.shared.neverSleepHosts.contains(host)
            add(never ? "Autoriser la mise en veille de \(host)" : "Ne jamais mettre en veille \(host)") {
                var hosts = SettingsStore.shared.neverSleepHosts
                if never { hosts.removeAll { $0 == host } } else { hosts.append(host) }
                SettingsStore.shared.neverSleepHosts = hosts
                if !never { tab.thaw() }
            }
        }
        if let host = ProtectionPolicy.normalized(tab.currentURL?.host), tab.currentURL?.scheme?.hasPrefix("http") == true {
            let off = ProtectionPolicy.isExempt(host: host, list: SettingsStore.shared.protectionExemptHosts)
            add(off ? "Réactiver les protections sur \(host)" : "Désactiver les protections sur \(host)") { [weak self] in
                var list = SettingsStore.shared.protectionExemptHosts
                if off { list.removeAll { host == $0 || host.hasSuffix("." + $0) } } else { list.append(host) }
                SettingsStore.shared.protectionExemptHosts = list
                tab.webView?.reload()
                _ = self
            }
        }
        add("Mettre en veille", enabled: !tab.isSuspended && tab.webView != nil && (tab.id != activeTabID || visibleTabs().count > 1)) { [weak self] in
            self?.sleepTab(tab)
        }
        let moveItem = NSMenuItem(title: "Déplacer vers…", action: nil, keyEquivalent: "")
        let moveMenu = NSMenu()
        for (index, name) in spaces.map(\.name).enumerated() where index != tab.spaceIndex {
            moveMenu.addItem(ClosureMenuItem(title: name) { [weak self] in self?.moveTab(tab, toSpace: index) })
        }
        moveItem.submenu = moveMenu
        menu.addItem(moveItem)
        menu.addItem(.separator())
        add("Fermer les autres onglets", enabled: tabs.filter({ $0.spaceIndex == tab.spaceIndex }).count > 1) { [weak self] in
            guard let self else { return }
            for other in self.tabs where other.id != tab.id && other.spaceIndex == tab.spaceIndex { self.closeTab(other) }
        }
        add("Fermer l'onglet") { [weak self] in self?.closeTab(tab) }
        return menu
    }

    /// Puts a tab to sleep by hand. The active tab first hands over to a neighbour in its space.
    func sleepTab(_ tab: Tab) {
        guard !tab.isSuspended, tab.webView != nil else { return }
        if splitContains(tab.id) { endSplit(keeping: nil) }
        if tab.id == activeTabID {
            guard let other = visibleTabs().first(where: { $0.id != tab.id }) else { return }
            selectTab(other)
        }
        Task { await tab.suspend() }
    }

    /// ⌥⌘E
    @objc func sleepActiveTab() { if let tab = activeTab { sleepTab(tab) } }

    /// ⌘⇧T
    @objc func reopenClosedTab() {
        guard let closed = closedTabs.popLast() else { return }
        let tab = Tab(configuration: makeConfiguration(isPrivate: false), isPrivate: false,
                      sleeping: (closed.url, closed.state, closed.title))
        tab.spaceIndex = closed.space
        attachTab(tab)
        selectTab(tab)   // wakes it
        saveSession()
    }

    /// ⌘1…⌘8 jump to that tab; ⌘9 always goes to the last one (browser convention).
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        guard !tabs.isEmpty else { return }
        let index = sender.tag == 9 ? tabs.count - 1 : sender.tag - 1
        if tabs.indices.contains(index) { selectTab(tabs[index]) }
    }

    @objc func moveActiveTabUp() { moveActiveTab(by: -1) }
    @objc func moveActiveTabDown() { moveActiveTab(by: 1) }

    private func tab(for webView: WKWebView) -> Tab? {
        tabs.first { $0.webView === webView }
    }

    /// The pointer rests on a sleeping tab: wake it in the background so the click finds it ready.
    /// Skipped when the Mac is already over the memory budget.
    private func prewake(_ tab: Tab) {
        guard tab.isSuspended, !isOverBudget else { return }
        tab.lastActiveDate = Date()   // counts as touched: it must not be put straight back to sleep
        ensureAwake(tab)
    }

    /// WebKit's private "first real content painted" signal (see `Tab.contentRenderedEvents`): the
    /// right moment to swap the snapshot for the live page. Ignored if this WebKit never calls it.
    @objc(_webView:renderingProgressDidChange:)
    func webViewRenderingProgress(_ webView: WKWebView, events: UInt) {
        guard events & Tab.contentRenderedEvents != 0, let tab = tab(for: webView) else { return }
        clearWakeRevealIfNeeded(for: tab)
    }

    /// The first time a freshly-woken tab's page reports anything (even a
    /// provisional navigation start), its stale snapshot can come down.
    private func clearWakeRevealIfNeeded(for tab: Tab) {
        guard tab.isAwaitingWakeReveal else { return }
        tab.finishWakeReveal()
    }

    // MARK: - Session restoration

    /// Benchmarks and tests launch with `HB_FRESH_SESSION=1`: start empty and
    /// never touch the saved session.
    private let isFreshSession = ProcessInfo.processInfo.environment["HB_FRESH_SESSION"] == "1"

    private func restoreSessionOrOpenFreshTab(openFreshTab: Bool = true) {
        let snapshots = isFreshSession ? [] : ((try? sessionRepo.load()) ?? [])
        guard !snapshots.isEmpty else {
            if openFreshTab { newTab(urlString: nil, isPrivate: SettingsStore.shared.privateByDefault) }
            return
        }

        let restorable = snapshots.filter { !$0.url.isEmpty }
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
    }

    /// Brings back the split screen of the previous session (same two tabs, same ratio).
    private func restoreSplit() {
        let saved = UserDefaults.standard.array(forKey: Self.splitKey) as? [Int] ?? []
        guard saved.count == 2, tabs.indices.contains(saved[0]), tabs.indices.contains(saved[1]) else { return }
        let ratio = UserDefaults.standard.double(forKey: Self.splitRatioKey)
        beginSplit(left: tabs[saved[0]], right: tabs[saved[1]])
        if (0.25...0.75).contains(ratio), ratio != 0.5 { setSplitRatio(CGFloat(ratio), animated: false) }
    }

    /// Benchmarks (`HB_DB_PATH` set) use their own key so they never overwrite the real one.
    private static let splitKey = ProcessInfo.processInfo.environment["HB_DB_PATH"] == nil ? "session.split" : "session.split.bench"
    private static let splitRatioKey = splitKey + ".ratio"
    private static let activeIndexKey = ProcessInfo.processInfo.environment["HB_DB_PATH"] == nil ? "session.activeIndex" : "session.activeIndex.bench"

    /// Captures every open (non-private) tab's URL/interaction state and
    /// persists the whole set. Called after every structural change (tab
    /// opened/closed/reordered/navigated) rather than only at quit, so a
    /// crash loses only the last few seconds, not the whole window. Works
    /// for suspended tabs too — `currentURL`/`currentInteractionState` fall
    /// back to what was captured right before suspension.
    private func saveSession() {
        guard !isFreshSession else { return }
        // Tabs with no address (failed load, blank page) aren't worth restoring —
        // they used to come back as empty tabs and pile up on every launch.
        let savable = tabs.filter { $0.currentURL != nil && $0.currentURL?.absoluteString != "about:blank" && $0.currentURL?.scheme != "oree" }
        if let activeTab, let index = savable.firstIndex(where: { $0.id == activeTab.id }) {
            UserDefaults.standard.set(index, forKey: Self.activeIndexKey)
        }
        UserDefaults.standard.set(currentSpace, forKey: Self.activeSpaceKey)
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

    // MARK: - Navigation

    private func load(urlString raw: String, in tab: Tab) {
        var urlString = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else { return }
        if !urlString.contains("://") {
            if Self.looksLikeAddress(urlString) {
                // localhost / host:port are dev servers that rarely speak TLS.
                let isLocal = urlString.hasPrefix("localhost") || urlString.range(of: #"^[\w.-]+:\d{2,5}"#, options: .regularExpression) != nil
                urlString = "\(isLocal ? "http" : "https")://\(urlString)"
            } else {
                let query = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString
                urlString = "\(SettingsStore.shared.searchEngine.queryURL)?q=\(query)"
            }
        }
        guard let url = URL(string: urlString) else { return }
        tab.lastRequestedURL = url
        tab.webView?.load(URLRequest(url: url))
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(
                    onPinnedSitesChanged: { [weak self] in self?.refreshPinnedIcons() },
                    onUpdateFilterLists: { [weak self] in
                        guard let blocker = self?.contentBlocker else { return }
                        Task { await blocker.updateNow() }
                    },
                    onOpenCustomize: { [weak self] in self?.settingsWindow?.close(); self?.openCustomize() },
                    extensions: extensionManager
                )
            )
            let window = NSWindow(contentViewController: hosting)
            window.title = "Réglages"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 800, height: 600))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// ⌘T: opens the palette; whatever you pick or type opens in a new tab.
    /// A URL handed to us by the system: a link clicked in another app, or an .html file.
    public func openExternal(_ url: URL) {
        let isPrivate = SettingsStore.shared.privateByDefault
        if url.isFileURL {
            let tab = newTab(urlString: nil, isPrivate: isPrivate)
            tab.lastRequestedURL = url
            tab.webView?.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else if url.scheme == "http" || url.scheme == "https" {
            newTab(urlString: url.absoluteString, isPrivate: isPrivate)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    /// ⌘T — a new tab on the home page with the address field ready to type in.
    @objc func newTabAction() {
        newTab(urlString: nil, isPrivate: SettingsStore.shared.privateByDefault)
        addressPill.beginEditing(text: "", selectAll: false)
    }

    @objc func newPrivateTabAction() {
        newTab(urlString: nil, isPrivate: true)
    }

    @objc func closeActiveTabAction() {
        if let tab = activeTab { closeTab(tab) }
    }

    @objc func goBack() { activeTab?.webView?.goBack() }
    @objc func goForward() { activeTab?.webView?.goForward() }
    @objc func reloadAction() { activeTab?.webView?.reload() }
    @objc func stopLoadingAction() { activeTab?.webView?.stopLoading() }

    /// Loading indicator: swaps the reload button into a stop button while
    /// the active tab's page is loading, and back again once it settles.
    private func updateLoadingIndicator(for tab: Tab) {
        guard tab.id == activeTabID else { return }
        downloads.pageLoading(tab.webView?.isLoading == true)       // downloads yield to the page being loaded
        if tab.webView?.isLoading == true {
            reloadButton.symbol = "xmark"
            reloadButton.onClick = { [weak self] in self?.stopLoadingAction() }
            reloadButton.setAccessibilityLabel("Arrêter le chargement")
        } else {
            reloadButton.symbol = "arrow.clockwise"
            reloadButton.onClick = { [weak self] in self?.reloadAction() }
            reloadButton.setAccessibilityLabel("Recharger la page")
        }
    }

    @objc func findInPage() {
        findBarContainer?.isHidden = false
        window?.makeFirstResponder(findField)
    }

    @objc func closeFindBar() {
        findBarContainer?.isHidden = true
        activeTab?.webView?.evaluateJavaScript("window.getSelection().removeAllRanges()")
        if let webView = activeTab?.webView {
            window?.makeFirstResponder(webView)
        }
    }

    @objc func findNext() { runFind(backwards: false) }
    @objc func findPrevious() { runFind(backwards: true) }

    private func runFind(backwards: Bool) {
        guard let tab = activeTab else { return }
        let term = findField.stringValue
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        guard !term.isEmpty else { return }
        let js = "window.find('\(term)', false, \(backwards), true, false, true, false)"
        tab.webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    @objc func addBookmark() {
        guard let tab = activeTab, let url = tab.webView?.url else { return }
        do {
            try bookmarkRepo.add(url: url.absoluteString, title: tab.displayTitle)
        } catch {
            Log.storage.error("Failed to add bookmark: \(error.localizedDescription)")
        }
        menuBuilder?.refreshBookmarksMenu()
        refreshPinnedIcons()
    }

    @objc func historyItemClicked(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String, let tab = activeTab else { return }
        load(urlString: urlString, in: tab)
    }

    @objc func bookmarkItemClicked(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String, let tab = activeTab else { return }
        load(urlString: urlString, in: tab)
    }

    private func syncToolbar(for tab: Tab) {
        let url = tab.webView?.url ?? tab.currentURL
        addressPill.show(url: (url?.scheme == "http" || url?.scheme == "https") ? url : nil)
        backButton.isEnabled = tab.webView?.canGoBack ?? false
        forwardButton.isEnabled = tab.webView?.canGoForward ?? false
        window?.title = tab.displayTitle
        updateLoadingIndicator(for: tab)
    }

    func recentHistoryForMenu(limit: Int = 15) -> [HistoryEntry] {
        (try? historyRepo.recent(limit: limit)) ?? []
    }

    func allBookmarksForMenu() -> [Bookmark] {
        (try? bookmarkRepo.all()) ?? []
    }

    // MARK: - Tab suspension (memory optimization)

    private func startSuspensionTimer() {
        suspensionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.suspendInactiveTabs() }
        }
    }

    /// Steady-state hygiene, once a minute: same pass as the memory timer (freeze / sleep by idle time).
    private func suspendInactiveTabs() async {
        await enforceMemoryBudget()
    }

    /// Emergency response: the OS just told us real memory is tight. Discard
    /// background tabs immediately, regardless of how recently they were
    /// used, oldest-touched first, to hand memory back right away rather
    /// than wait for the idle timer. Uses the public `DispatchSource`
    /// memory-pressure API — no private WebKit hooks involved.
    private func startMemoryPressureMonitor() {
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

    private func suspendAllBackgroundTabs() async {
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
        await apply(TabLifecyclePolicy.emergencyPlan(entries: entries))
    }

    // MARK: - WKNavigationDelegate

    /// Main-frame gatekeeper: URL cleaning, HTTPS-only upgrade, Safe Browsing,
    /// then per-page scripts. Sub-frames and non-web schemes pass straight through.
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let policy = await decideNavigation(webView, navigationAction, preferences)
        return (policy, preferences)
    }

    private func decideNavigation(_ webView: WKWebView, _ navigationAction: WKNavigationAction, _ preferences: WKWebpagePreferences) async -> WKNavigationActionPolicy {
        if let url = navigationAction.request.url, url.scheme == StartPage.actionScheme {
            handleHomeAction(url)
            return .cancel
        }
        if navigationAction.shouldPerformDownload { return .download }
        guard navigationAction.targetFrame?.isMainFrame == true,
              let original = navigationAction.request.url,
              let scheme = original.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let tab = tab(for: webView) else { return .allow }

        let settings = SettingsStore.shared
        var target = original
        tab.lastRequestedURL = original
        if tab.id == activeTabID { Task { await makeRoom(forNavigationTo: original, in: tab) } }

        // Tracking parameters: only on plain GET loads the user/page started,
        // never on reload / back-forward (those must replay exactly).
        let type = navigationAction.navigationType
        if settings.urlCleaning, navigationAction.request.httpMethod == "GET", type != .reload, type != .backForward {
            target = urlCleaner.clean(target)
        }

        if target != original {
            webView.load(URLRequest(url: target))
            return .cancel
        }

        // HTTPS-only: WebKit upgrades http:// itself (no cancel-and-reload round
        // trip) and reports a plain failure if the site has no HTTPS, which
        // is where our "continue over HTTP?" screen takes over.
        if case .upgrade(let secure) = HTTPSPolicy(isEnabled: settings.httpsOnly).decision(for: target, exemptHosts: httpExemptHosts) {
            let host = target.host?.lowercased() ?? ""
            // A site that bounces https -> http forever must not trap us in a loop.
            if tab.upgradeAttempts[host, default: 0] < 2 {
                tab.upgradeAttempts[host, default: 0] += 1
                tab.upgradedFromHTTP = target
                if #available(macOS 15.2, *) {
                    preferences.preferredHTTPSNavigationPolicy = .errorOnFailure
                } else {
                    webView.load(URLRequest(url: secure))   // older macOS: cancel and reload over https
                    return .cancel
                }
            }
        } else if #available(macOS 15.2, *) {
            preferences.preferredHTTPSNavigationPolicy = .keepAsRequested
        }

        if let client = safeBrowsing, let host = original.host?.lowercased(), !safeBrowsingBypass.contains(host),
           let threat = await client.check(original) {
            showUnsafeSiteWarning(threat, url: original, in: tab)
            return .cancel
        }

        // Blocking switched off for sites that break when only partly blocked (see ProtectionPolicy).
        let exempt = ProtectionPolicy.isExempt(host: original.host, list: settings.protectionExemptHosts)
        tab.applyContentRuleLists(settings.adBlockEnabled && !exempt ? contentBlocker.ruleLists : [])
        tab.setUserScripts(userScripts(for: original))
        return .allow
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let tab = tab(for: webView) { updateLoadingIndicator(for: tab) }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let tab = tab(for: webView) else { return }
        updateLoadingIndicator(for: tab)
        tab.tabButton.setTitle(tab.displayTitle, host: tab.badgeHost)
        let nsError = error as NSError
        Log.network.notice("Provisional navigation failed: \(nsError.domain, privacy: .public) \(nsError.code)")
        // Cancellations (we cancelled it ourselves, or a download/redirect took over) aren't failures.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }

        guard let httpURL = tab.upgradedFromHTTP, HTTPSPolicy.shouldOfferHTTPFallback(for: error) else {
            let failedURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
            let host = failedURL?.host ?? failedURL?.absoluteString ?? "cette adresse"
            let goBack: @MainActor () -> Void = { [weak tab] in
                guard let tab else { return }
                tab.interstitial.hide()
                if tab.webView?.canGoBack == true { tab.webView?.goBack() }
            }
            switch LoadFailure.classify(error) {
            case .certificate(let problem):
                tab.interstitial.show(.connectionNotPrivate(host: host, reason: problem.message, goBack: goBack))
            case let failure:
                tab.interstitial.show(.loadFailed(
                    host: host,
                    reason: failure.message,
                    retry: { [weak tab] in
                        guard let tab else { return }
                        tab.interstitial.hide()
                        if let failedURL { tab.webView?.load(URLRequest(url: failedURL)) } else { tab.webView?.reload() }
                    }
                ))
            }
            return
        }
        let host = httpURL.host?.lowercased() ?? ""
        tab.upgradedFromHTTP = nil
        tab.interstitial.show(.httpFallback(
            host: host,
            goBack: { [weak tab] in
                guard let tab else { return }
                tab.interstitial.hide()
                if tab.webView?.canGoBack == true { tab.webView?.goBack() }
            },
            continueOverHTTP: { [weak self, weak tab] in
                guard let self, let tab else { return }
                self.httpExemptHosts.insert(host)
                tab.interstitial.hide()
                tab.webView?.load(URLRequest(url: httpURL))
            }
        ))
    }

    /// Shown in the page, or saved as a download? (The async form is the one WebKit actually matches — the
    /// completion-handler form only "nearly matched" the protocol and was silently never called, so no
    /// download ever started from a response.)
    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        // Files the server marks as attachments (or that WebKit can't display) are downloads, like in Safari.
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
           disposition.hasPrefix("attachment") {
            return .download
        }
        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    /// `<a download>` links and "Save link as…": the engine asks for a download instead of a navigation.
    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        updateLoadingIndicator(for: tab)
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        tab.interstitial.hide()
        tab.pageDidCommit()
        tab.revealWebView()
        if !firstCommitTraced { firstCommitTraced = true; LaunchTrace.mark("first page committed") }
        extensionManager.tabChanged(tab, [.URL, .loading, .title])
        tab.tabButton.setTitle(tab.displayTitle, host: tab.badgeHost)
        if tab.id == activeTabID {
            syncToolbar(for: tab)
        }
    }

    /// The WebContent process backing this tab's page crashed (OOM, bug,
    /// etc). The tab itself is unaffected — show a "Recharger" screen in
    /// place of the dead page instead of closing the tab or reloading
    /// automatically (which could loop forever if the page itself is what's
    /// crashing the process).
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        Log.tabs.error("WebContent process terminated for tab \(tab.id.uuidString, privacy: .public)")
        tab.interstitial.show(.crashed { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.recoverFromCrash(tab)
        })
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        tab.tabButton.setTitle(tab.displayTitle, host: tab.badgeHost)
        clearWakeRevealIfNeeded(for: tab)
        tab.restorePageStateIfNeeded()
        tab.revealWebView()
        extensionManager.tabChanged(tab, [.loading, .title])
        tab.upgradedFromHTTP = nil
        tab.upgradeAttempts = [:]
        if let url = webView.url, url.absoluteString != "about:blank", url.scheme != "oree", !tab.isPrivate {
            do {
                try historyRepo.recordVisit(url: url.absoluteString, title: tab.displayTitle)
            } catch {
                Log.storage.error("Failed to record history visit: \(error.localizedDescription)")
            }
            menuBuilder?.refreshHistoryMenu()
        }
        if tab.id == activeTabID {
            syncToolbar(for: tab)
        }
        saveSession()
    }

    // MARK: - WKUIDelegate (permissions)

    public func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        let kinds: [SitePermission]
        switch type {
        case .camera: kinds = [.camera]
        case .microphone: kinds = [.microphone]
        default: kinds = [.camera, .microphone]
        }
        return await decidePermission(kinds, origin: origin, webView: webView)
    }

    // Geolocation permission prompts only exist in the macOS 27 WebKit API.
    @available(macOS 27.0, *)
    public func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo) async -> WKPermissionDecision {
        await decidePermission([.location], origin: origin, webView: webView)
    }

    // MARK: - WKUIDelegate (popups open as tabs)

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let isPrivate = tab(for: webView)?.isPrivate ?? false
        let newTab = Tab(configuration: configuration, isPrivate: isPrivate)
        newTab.spaceIndex = tab(for: webView)?.spaceIndex ?? currentSpace
        attachTab(newTab)
        selectTab(newTab)
        return newTab.webView
    }

    // MARK: - WKDownloadDelegate

    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let isPrivate = !(download.webView?.configuration.websiteDataStore.isPersistent ?? true)
        return await downloads.handle(download, response: response, suggestedFilename: suggestedFilename,
                                      pageURL: download.webView?.url, isPrivate: isPrivate)
    }

    public func downloadDidFinish(_ download: WKDownload) { downloads.webkitFinished(download) }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        Log.network.error("Download failed: \(error.localizedDescription, privacy: .public)")
        downloads.webkitFailed(download, error: error, resumeData: resumeData)
    }
}

/// Top-anchored document view so scrolled content starts at the top.
final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Receives `hbCreds` messages. Held separately (not the controller itself)
/// so the web view's user-content controller doesn't retain the window controller.
@MainActor
final class CredentialMessageHandler: NSObject, WKScriptMessageHandler {
    var onMessage: ((WKWebView, String, [String: Any]) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, let body = message.body as? [String: Any] else { return }
        let origin = message.frameInfo.securityOrigin
        let originString = origin.port > 0 ? "\(origin.protocol)://\(origin.host):\(origin.port)" : "\(origin.protocol)://\(origin.host)"
        onMessage?(webView, originString, body)
    }
}

/// An NSMenuItem that runs a closure (menus built on the fly don't need a target/action per item).
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func run() { handler() }
}


// MARK: - Extensions (engine <-> our window)

extension BrowserWindowController {
    /// Tabs extensions are allowed to see (never private ones).
    var extensionTabs: [Tab] { tabs.filter { !$0.isPrivate } }
    var activeExtensionTab: Tab? { activeTab.flatMap { $0.isPrivate ? nil : $0 } }

    /// Rebuilds the sidebar's row of extension buttons (icon, badge) for the current tab.
    func refreshExtensionToolbar() {
        let entries = extensionManager.toolbarEntries(for: activeExtensionTab)
        let ids = Set(entries.map(\.id))
        for (id, button) in extensionButtons where !ids.contains(id) {
            extensionBar.removeArrangedSubview(button)
            button.removeFromSuperview()
            extensionButtons[id] = nil
        }
        for entry in entries {
            let button: ExtensionButton
            if let existing = extensionButtons[entry.id] {
                button = existing
            } else {
                let id = entry.id
                button = ExtensionButton(extensionID: id) { [weak self] in
                    guard let self else { return }
                    self.extensionManager.performAction(id: id, for: self.activeExtensionTab)
                }
                extensionButtons[id] = button
                extensionBar.addArrangedSubview(button)
            }
            button.update(from: entry.action)
        }
        extensionBar.isHidden = entries.isEmpty
    }

    /// Shows an extension's popup next to its toolbar button.
    func presentExtensionPopup(_ action: WKWebExtension.Action, for context: WKWebExtensionContext) {
        guard let popover = action.popupPopover else { return }
        let anchor: NSView = extensionButtons[context.uniqueIdentifier] ?? addressPill
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
}

extension BrowserWindowController: WKWebExtensionWindow {
    @objc(tabsForWebExtensionContext:)
    public func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { extensionTabs }

    @objc(activeTabForWebExtensionContext:)
    public func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { activeExtensionTab }

    @objc(windowTypeForWebExtensionContext:)
    public func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    @objc(windowStateForWebExtensionContext:)
    public func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        window?.styleMask.contains(.fullScreen) == true ? .fullscreen : (window?.isMiniaturized == true ? .minimized : .normal)
    }

    @objc(isPrivateForWebExtensionContext:)
    public func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    @objc(frameForWebExtensionContext:)
    public func frame(for context: WKWebExtensionContext) -> CGRect { window?.frame ?? .zero }

    @objc(screenFrameForWebExtensionContext:)
    public func screenFrame(for context: WKWebExtensionContext) -> CGRect { window?.screen?.frame ?? .zero }

    @objc(focusForWebExtensionContext:completionHandler:)
    public func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }
}



