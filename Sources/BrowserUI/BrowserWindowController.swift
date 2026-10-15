import AppKit
import WebKit
import SwiftUI
import BrowserCore
import BrowserStorage
import BrowserSettingsUI
import DownloadKit
import OreeObjC
import MediaPlayer

public final class BrowserWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {

    public weak var menuBuilder: MenuBuilder?
    var settingsWindow: NSWindow?

    let contentBlocker: ContentBlockerManager
    nonisolated(unsafe) var settingsObserver: NSObjectProtocol?
    let processPool = ProcessPoolFactory.launchPool
    let privateProcessPool = ProcessPoolFactory.makeLeanProcessPool()
    var tabs: [Tab] = []
    var activeTabID: UUID?
    // `nonisolated(unsafe)`: only touched from `deinit`, which (unlike the
    // rest of this @MainActor-inferred class) is never actor-isolated in
    // Swift 6 — invalidating a Timer / canceling a dispatch source is
    // documented thread-safe, so there's no real data race here.
    nonisolated(unsafe) var suspensionTimer: Timer?
    nonisolated(unsafe) var memoryPressureSource: DispatchSourceMemoryPressure?

    let historyRepo = HistoryRepository()
    let bookmarkRepo = BookmarkRepository()
    let sessionRepo = SessionRepository()
    let groupRepo = TabGroupRepository()
    let oreeSchemeHandler = OreeSchemeHandler()
    /// Tab groups of every space, in display order.
    lazy var groups: [TabGroup] = (try? groupRepo.load()) ?? []
    let permissionRepo = SitePermissionRepository()
    let vault = CredentialVault()
    let credentialHandler = CredentialMessageHandler()
    /// (origin, username) pairs the user said "not now" to, until quit.
    var declinedSaves: Set<String> = []
    var credentialPromptInFlight = false

    // Security / privacy state (Phase 3)
    let fingerprintSeed = UInt32.random(in: .min ... .max)
    lazy var urlCleaner = URLCleaner.bundled   // compiling its regexes cost ~10 ms of every start
    /// Hosts the user chose to open over plain HTTP, until the app quits.
    var httpExemptHosts: Set<String> = []
    /// Hosts whose Safe Browsing warning the user chose to ignore, until quit.
    var safeBrowsingBypass: Set<String> = []
    var safeBrowsing: SafeBrowsingClient?
    var safeBrowsingKey = ""
    var safeBrowsingUpdateTask: Task<Void, Never>?
    var lastFingerprintSetting: Bool?
    var lastLongPagesSetting: Bool?

    let tabBarStack = NSStackView()
    let pinnedStack = NSStackView()
    let newTabButton = NSButton()
    let contentContainer = SurfaceView(fill: Theme.page)

    let extensionManager = ExtensionManager()
    let extensionBar = NSStackView()
    var extensionButtons: [String: ExtensionButton] = [:]
    let loadingBar = LoadingBarView()
    let noticePill = NoticePill()
    let nowPlaying = NowPlayingView()
    let audioRoute = AudioRoute()
    var mediaTabID: UUID?                      // the tab the card is about
    var siteInfoPopover: NSPopover?
    /// The window of a page's alert / confirm / prompt while it is open (kept so that a test can see and answer it).
    var activeWebDialog: NSAlert?
    /// Tabs in the order they were last in front (most recent first): ⌃Tab goes back to the previous one, like Alt-Tab does for apps.
    var recentTabIDs: [UUID] = []
    var qrPopover: NSPopover?
    var tabPreviewPopover: NSPopover?
    var tabPreviewTask: Task<Void, Never>?
    var taskManager: TaskManagerWindowController?
    var artworkCache: [String: NSImage] = [:]
    var artworkRequested: Set<String> = []
    var shownArtwork: String?
    var webStoreOffered: [String: Date] = [:]   // when the "add to Orée" offer of each extension was last shown
    /// La barre IA, créée à la première ouverture (rien ne démarre avant : ni l'agent, ni la connexion au service).
    var aiBarController: AIPanelController?
    /// Écart entre le bord droit de la page et celui de la fenêtre quand le panneau IA pousse la page.
    var pageTrailing: NSLayoutConstraint?
    var pageMapResult = "(none)"
    let digestPanel = DigestPanelView()
    let peekPanel = PeekPanelView()
    lazy var webPanel = WebPanelView { [unowned self] _ in self.makeConfiguration(isPrivate: false) }
    let digestButton = ChromeIconButton(symbol: "list.bullet.clipboard", label: "Afficher l'essentiel")
    let calendarButton = ChromeIconButton(symbol: "calendar.badge.plus", label: "Ajouter au Calendrier")
    var eventTask: Task<Void, Never>?
    var digestTask: Task<Void, Never>?
    var digestCache: [String: PageDigest] = [:]
    /// The page the pop-up is about, and the pages whose pop-up the user closed (so a recipe does not keep reopening it).
    let boostRepo = BoostRepository()
    var boostTask: Task<Void, Never>?
    var lastBoostSignature = ""
    var digestKey: String?
    var digestDismissed: Set<String> = []
    let readingBar = SurfaceView()
    var readingBarWidth: NSLayoutConstraint?
    let resumeRepo = ResumeRepository()
    var aiResult = "none"
    let addressPill = AddressPillView()
    let spaceRail = SpaceRailView()
    let spaceNameLabel = NSTextField(labelWithString: "")
    let spaceMetaLabel = NSTextField(labelWithString: "")
    var toolbar: ToolbarView!
    var tabColumn: NSView?
    var railWidth: NSLayoutConstraint?
    /// Full-window panels (customize, welcome, spaces overview, palette) are built the first time they are needed,
    /// not at launch: they are invisible until then, and building them cost ~50 ms of every start.
    var drawerLoaded = false
    lazy var drawer: CustomizeDrawerView = {
        drawerLoaded = true
        let view = CustomizeDrawerView()
        installOverlay(view)
        view.onClose = { [weak self] in self?.closeCustomize() }
        view.onChange = { [weak self] in self?.applyLookChanges() }
        view.onPickPhoto = { [weak self] in self?.pickHomePhoto() }
        return view
    }()
    let sidePanel = SidePanelView()
    let readingRepo = ReadingListRepository()
    let noteRepo = NoteRepository()
    var notesPopover: NSPopover?
    var notesView: NotesPanelView?
    var panelButtons: [(kind: PanelKind, button: ChromeIconButton)] = []
    var activePanel: PanelKind?
    var panelScroll: NSScrollView?
    let sleepMetaLabel = NSTextField(labelWithString: "")
    enum PanelKind { case favorites, history, downloads, reading }
    let tabStrip = TabStripView()
    var stripHeight: NSLayoutConstraint?
    let addressDropdown = AddressDropdownView()
    let downloads = DownloadsController()
    var downloadsPanel: DownloadsPanelView?
    let downloadsButton = ChromeIconButton(symbol: "arrow.down.to.line", label: "Téléchargements")
    var downloadsPopover: NSPopover?
    // Split screen: two tabs side by side (not restored at launch).
    var splitPair: (left: UUID, right: UUID)?
    var splitRatio: CGFloat = 0.5
    var splitHeaders: [UUID: SplitPaneHeader] = [:]
    var splitHinge: SplitHingeView?
    var splitConstraints: [NSLayoutConstraint] = []
    var splitLeftWidth: NSLayoutConstraint?
    var splitMonitor: Any?
    let splitButton = ChromeIconButton(symbol: "rectangle.split.2x1", label: "Écran partagé  ⌘\\")
    let translateButton = ChromeIconButton(symbol: "translate", label: "Traduire la page")
    let nightButton = ChromeIconButton(symbol: "moon", label: "Mode nuit")
    var appearanceObservation: NSKeyValueObservation?
    lazy var overview: SpacesOverviewView = {
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
    lazy var onboarding: OnboardingView = {
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
    var searchRow: SidebarRowView?
    var newTabRow: SidebarRowView?
    let collapseButton = ChromeIconButton(symbol: "sidebar.left", label: "Réduire la barre latérale")
    var paletteLoaded = false
    lazy var palette: CommandPaletteView = {
        paletteLoaded = true
        let view = CommandPaletteView()
        installOverlay(view)
        view.provider = { [weak self] query, filter in self?.paletteSections(query: query, filter: filter) ?? [] }
        view.onDismiss = { [weak self] in self?.closePalette() }
        return view
    }()

    /// Pins a full-window panel over everything else.
    func installOverlay(_ view: NSView) {
        guard let content = window?.contentView else { return }
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: content.topAnchor), view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor), view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }
    let favoritesStack = NSStackView()
    let backButton = ChromeIconButton(symbol: "chevron.left", label: "Page précédente  ⌘[")
    let forwardButton = ChromeIconButton(symbol: "chevron.right", label: "Page suivante  ⌘]")
    let reloadButton = ChromeIconButton(symbol: "arrow.clockwise", label: "Recharger  ⌘R")
    let toggleSidebarButton = ChromeIconButton(symbol: "sidebar.left", label: "Afficher la barre latérale  ⌥⌘S")
    let customizeButton = ChromeIconButton(symbol: "paintbrush", label: "Personnaliser  ⌘,")
    let moreButton = ChromeIconButton(symbol: "ellipsis", label: "Palette de commandes  ⌘K")
    let assistantButton = ChromeIconButton(symbol: "sparkles", label: "Assistant (Luciole)  ⌘J")
    /// La rangée de boutons du bas de la barre latérale, et ce qui la complète à droite (espace libre, « N en veille »).
    var footerStack: NSStackView?
    var footerTail: [NSView] = []
    /// Les boutons « selon la page » qui servent en ce moment ; la disposition (`ChromeLayout`) décide où ils vont et s'ils restent à leur place.
    var chromeRelevant: Set<ChromeItem> = []
    var appliedChromeLayout: ChromeLayout?
    var sidebarView: NSView?
    var sidebarWidth: NSLayoutConstraint?
    var sidebarLeading: NSLayoutConstraint?
    /// Height of the title row (traffic lights + toolbar) at the top of the sidebar.
    var topRow: CGFloat { isFullScreen ? 44 : CGFloat(OreeTokens.Metrics.toolbarHeight) }
    var resizeHandleTop: NSLayoutConstraint?
    var columnTop: NSLayoutConstraint?
    var isFullScreen = false
    let titleToolbar: NSToolbar = { let t = NSToolbar(identifier: "oree.titlebar"); t.showsBaselineSeparator = false; return t }()
    var sidebarTop: NSLayoutConstraint?
    var sidebarBottom: NSLayoutConstraint?
    let sidebarGlassView: NSView = SidebarGlass.makeBackground()
    let resizeHandle = SidebarResizeHandle()
    let hoverSpaceRow = NSStackView()
    var mainLeading: NSLayoutConstraint?
    let mainGuide = NSLayoutGuide()
    let edgeTrigger = EdgeTriggerView()
    var floatingShown = false
    // Hover-sidebar behavior: show after a short intent delay, hide shortly after the pointer leaves it —
    // unless a menu is open, the edge is being dragged, or the pointer came back.
    var floatingShowWork: DispatchWorkItem?
    var floatingHideWork: DispatchWorkItem?
    var floatingClickMonitor: Any?
    var floatingMenuTracking = false
    var isResizingSidebar = false
    static let sidebarExpandedWidth = CGFloat(OreeTokens.Metrics.sidebarWidth)

    let findBar = NSStackView()
    let findField = NSTextField()
    var findBarContainer: NSView?

    var activeTab: Tab? {
        tabs.first { $0.id == activeTabID }
    }

    public init(contentBlocker: ContentBlockerManager, isSecondary: Bool = false) {
        self.contentBlocker = contentBlocker
        self.isSecondary = isSecondary
        self.isFreshSession = isSecondary || ProcessInfo.processInfo.environment["HB_FRESH_SESSION"] == "1"

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

        if !isSecondary { try? permissionRepo.purgeSessionScoped() }      // a second window must not forget what the first one was told this session
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
        lastBlockingSettings = ["\(SettingsStore.shared.adBlockEnabled)"] + SettingsStore.shared.protectionExemptHosts
        contentBlocker.onRuleListsChanged = { [weak self] _ in self?.applyRuleLists() }
        // Settings write straight to UserDefaults; re-evaluate whatever
        // depends on them (e.g. the ad-block toggle) as soon as one changes.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSettingsReaction() }
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

    var automation: AutomationServer?
    var lastMemoryPressure: Date?
    var firstCommitTraced = false
    /// Recently closed tabs, newest last (⌘⇧T reopens the last one).
    var closedTabs: [(url: URL, state: Data?, title: String?, space: Int)] = []

    // Spaces: Perso / Travail / Lecture. Same cookies and logins everywhere (they only
    // group tabs); each tab belongs to exactly one, and only one space is visible.
    var currentSpace = 0
    var lastActiveTabInSpace: [Int: UUID] = [:]
    nonisolated(unsafe) var audioTimer: Timer?
    nonisolated(unsafe) var memoryBudgetTimer: Timer?
    var lastGarbageCollection = Date.distantPast
    let siteMemoryRepo = SiteMemoryRepository()
    var siteProfileCache: [String: SiteProfile?] = [:]
    static let benchSuffix = ProcessInfo.processInfo.environment["HB_DB_PATH"] == nil ? "" : ".bench"
    static let spaceNamesKey = "spaces.names" + benchSuffix
    static let spaceStylesKey = "spaces.styles" + benchSuffix
    static let activeSpaceKey = "session.activeSpace" + benchSuffix

    /// The user's spaces (name, hue, icon). Migrates the older names-only list on first read.
    lazy var spaces: [SpaceStyle] = {
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
    var currentSpaceStyle: SpaceStyle { spaces[min(currentSpace, spaces.count - 1)] }

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
            overlays: { [weak self] in [self?.activeTab?.interstitial, self?.loadingBar, self?.digestPanel, self?.noticePill, (self?.paletteLoaded == true ? self?.palette : nil), self?.addressDropdown, (self?.floatingShown == true ? self?.sidebarView : nil), self?.demoPanel, self?.drawer, self?.overview, self?.onboarding, self?.findBarContainer].compactMap { $0 } },
            tabOperation: { [weak self] op, index in
                guard let self, self.visibleTabs().indices.contains(index) else { return "no such tab" }
                let tab = self.visibleTabs()[index]
                #if DEBUG
                if let answer = self.devOp(op, tab) { return answer }
                #endif      // media, recorder, probes: kept out of this closure (the compiler gives up on a longer one)
                if op == "pagemap" || op == "pagemapget" || op == "act" || op == "actget" || op == "groqkey" || op == "cloudkey" { return self.pageMapOp(op, tab) }      // hors du `switch` : il est déjà à la limite du compilateur
                switch op {
                case "select": self.selectTab(tab); return "selected \(index)"
                case "sleep": self.sleepTab(tab); return "sleeping \(index)"
                case "prewake": self.prewake(tab); return "prewoken \(index)"
                case "translate": tab.translator.translate(); return tab.translator.report
                case "untranslate": tab.translator.restore(); return tab.translator.report
                case "translation": return tab.translator.report
                case "copy":
                    NSPasteboard.general.clearContents()
                    NSApp.sendAction(NSSelectorFromString("copy:"), to: tab.webView, from: nil)
                    return "copied"
                case "aibar": self.aiBar().toggle(); return self.aiBar().report
                case "aistate": return self.aiBarController?.report ?? "open=false (jamais ouverte)"
                case "aiquery":
                    // Dev: pose à la barre IA la question écrite dans /tmp/oree-ai-query.txt (la vraie question, par le vrai service).
                    guard let text = try? String(contentsOfFile: "/tmp/oree-ai-query.txt", encoding: .utf8) else { return "no query file" }
                    self.aiBar().ask(text.trimmingCharacters(in: .whitespacesAndNewlines)); return self.aiBar().report
                case "aiopensource":
                    #if DEBUG
                    if let text = try? String(contentsOfFile: "/tmp/oree-ai-query.txt", encoding: .utf8), let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) { self.aiBarController?.devOpenSource(url) }
                    return self.aiBarController?.report ?? "no panel"
                    #else
                    return "debug only"
                    #endif
                case "lucioleSheet":
                    #if DEBUG
                    return AIPanelController.devLucioleSheet(to: "/tmp/oree-luciole.png")
                    #else
                    return "debug only"
                    #endif
                case "aipanelshot":
                    #if DEBUG
                    return self.aiBarController?.devSnapshot(to: "/tmp/oree-panel.png") ?? "no panel"
                    #else
                    return "debug only"
                    #endif
                case "aistop": self.aiBarController?.stop(); return self.aiBarController?.report ?? ""
                case "airesolve":
                    // Dev : répond à la carte « à valider » (yes / no) ou à la question affichée (texte du fichier).
                    let answer = (try? String(contentsOfFile: "/tmp/oree-ai-query.txt", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "no"
                    self.aiBarController?.devResolve(answer); return self.aiBarController?.report ?? ""
                case "fmask":
                    // Dev: asks Apple's on-device model a fixed question and stores the answer for `aiget`.
                    self.aiResult = "pending"
                    let started = Date()
                    Task { @MainActor in
                        do {
                            let dir = "/tmp/oree-ai-"
                            let instructions = (try? String(contentsOfFile: dir + "instructions.txt", encoding: .utf8)) ?? "Réponds en une phrase, en français."
                            let prompt = (try? String(contentsOfFile: dir + "prompt.txt", encoding: .utf8)) ?? "Quelle est la capitale de la France ?"
                            let text = try await LocalModel.respond(instructions: instructions, prompt: prompt, seconds: 150)
                            self.aiResult = String(format: "%.1fs : ", Date().timeIntervalSince(started)) + text
                        } catch { self.aiResult = String(format: "%.1fs : ERREUR ", Date().timeIntervalSince(started)) + "\(error)" }
                    }
                    return "asked (available=\(LocalModel.isAvailable) reason=\(LocalModel.unavailableReason ?? "none"))"
                case "aiget": return self.aiResult
                case "digestshot":
                    let path = "/tmp/oree-digest.png"
                    let scroll = Int((try? String(contentsOfFile: "/tmp/oree-digest-scroll.txt", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
                    Task { @MainActor in await self.digestPanel.snapshot(to: path, scrollY: scroll) }
                    return "saving \(path)"
                case "eventget":
                    guard let event = tab.eventCandidate else { return "candidate=none" }
                    return "candidate=\(event.title) | \(ICSBuilder.build(event, uid: "test").replacingOccurrences(of: "\r\n", with: " / "))"
                case "eventmodel":
                    // Dev: the model path, result printed by `tab aiget` (no dialog, Calendar is never opened).
                    guard let web = tab.webView else { return "no web view" }
                    self.aiResult = "pending"
                    Task { @MainActor in
                        do {
                            let event = try await self.findEventWithModel(in: web)
                            self.aiResult = event.map { "event=\($0.title) start=\($0.start.ISO8601Format()) location=\($0.location ?? "-")" } ?? "event=none"
                        } catch { self.aiResult = "error=\(error)" }
                    }
                    return "started (model available: \(LocalModel.isAvailable))"
                case "boostapply":
                    // Dev: applies the JSON rules in /tmp/oree-boost.json to the current site (the model's answer format), skipping the model.
                    guard let host = tab.webView?.url?.host, let text = try? String(contentsOfFile: "/tmp/oree-boost.json", encoding: .utf8) else { return "no host or no file" }
                    let proposed = BoostPolicy.rules(fromModel: text)
                    try? self.boostRepo.save(Boost(host: host, prompt: "test", rules: proposed.rules, calm: proposed.calm))
                    self.refreshBoosts()
                    return "saved \(proposed.rules.count) rule(s) calm=\(proposed.calm)"
                case "boostmodel":
                    // Dev: the whole flow with the local model, the request read from /tmp/oree-boost-request.txt (no dialog).
                    guard let request = try? String(contentsOfFile: "/tmp/oree-boost-request.txt", encoding: .utf8) else { return "no request file" }
                    self.createBoost(request: request.trimmingCharacters(in: .whitespacesAndNewlines), for: tab)
                    return "started (model available: \(LocalModel.isAvailable))"
                case "boostreport":
                    let boosts = (try? self.boostRepo.all()) ?? []
                    return boosts.map { "\($0.host) rules=\($0.rules.count) calm=\($0.calm)" }.joined(separator: "; ") + " calmAll=\(SettingsStore.shared.calmModeEverywhere)"
                case "boostremove": self.removeBoostAction(); return "removed"
                case "digestservings":
                    let count = Int((try? String(contentsOfFile: "/tmp/oree-digest-servings.txt", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 4
                    self.aiResult = "pending"
                    Task { @MainActor in self.aiResult = await self.digestPanel.debugSetServings(count) }
                    return "set \(count) (read the result with `tab aiget`)"
                case "digestcook": self.digestPanel.debugToggleCooking(); return "cooking=\(self.digestPanel.isCooking) screenHeld=\(self.digestPanel.isScreenHeld)"
                case "digest": self.digestAction(); return "toggled state=\(self.digestPanel.state)"
                case "digestget": return "state=\(self.digestPanel.state) candidate=\(tab.digestCandidate.map { "\($0.kind.rawValue):\($0.ingredients.count)i/\($0.steps.count)s" } ?? "none") text=\(self.digestPanel.shownText.replacingOccurrences(of: "\n", with: " | ").prefix(700))"
                case "resume": return self.resumeReport(for: tab)
                case "pressnotice": self.noticePill.pressAction(); return "pressed"
                case "resumeforget":
                    if let key = ResumePolicy.key(for: tab.webView?.url) { try? self.resumeRepo.remove(key: key) }
                    return "forgotten"
                case "night":
                    let settings = SettingsStore.shared
                    return "mode=\(settings.nightMode.rawValue) active=\(NightPolicy.isActive(mode: settings.nightMode, appearanceIsDark: self.appearanceIsDark)) excluded=\(settings.nightExcludedHosts) native=\(settings.nightNativeHosts)"
                case "webshot":
                    // Dev: what WebKit itself draws for the page right now, even while the web view lives in another window.
                    guard let web = tab.webView else { return "no web view" }
                    Task { @MainActor in
                        guard let image = try? await web.takeSnapshot(configuration: nil), let tiff = image.tiffRepresentation,
                              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                        try? png.write(to: URL(fileURLWithPath: "/tmp/oree-webshot.png"))
                    }
                    return "saving /tmp/oree-webshot.png"
                case "geometry":
                    guard let web = tab.webView else { return "no web view" }
                    let slot = web.superview
                    return "fullscreenState=\(web.fullscreenState.rawValue) frame=\(web.frame) window=\(web.window === self.window ? "main" : (web.window == nil ? "none" : "other:\(web.window!.frame)")) superview=\(slot.map { String(describing: type(of: $0)) } ?? "nil") hidden=\(web.isHidden) alpha=\(web.alphaValue) constraintsOnSlot=\(slot?.constraints.filter { $0.firstItem === web || $0.secondItem === web }.count ?? -1) translates=\(web.translatesAutoresizingMaskIntoConstraints) mask=\(web.autoresizingMask.rawValue) mainFrame=\(self.window?.frame ?? .zero) appActive=\(NSApp.isActive) fsWindowVisible=\(web.window?.occlusionState.contains(.visible) ?? false) fsKey=\(web.window?.isKeyWindow ?? false) fsLevel=\(web.window?.level.rawValue ?? -1) fsScreen=\(web.window?.screen?.frame ?? .zero) fsOpaque=\(web.window?.isOpaque ?? false) wantsLayer=\(web.wantsLayer) layerHidden=\(web.layer?.isHidden ?? false) layerOpacity=\(web.layer?.opacity ?? -1)"
                case "nightsite": self.toggleNightForCurrentSite(); return "toggled"
                case "notice": return self.noticePill.visibleMessage ?? "(none)"
                case "pasteboard":
                    let board = NSPasteboard.general
                    var parts: [String] = []
                    for type in ["public.utf8-plain-text", "public.html"] {
                        let content = board.string(forType: NSPasteboard.PasteboardType(type)) ?? "(none)"
                        parts.append("[\(type)]\n" + content)
                    }
                    return parts.joined(separator: "\n")
                default: return "unknown op"
                }
            },
            ghostCheck: { [weak self] live, ghost in await self?.activeTab?.ghostSelfTest(livePath: live, ghostPath: ghost) ?? "no tab" },
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
    /// Ad / tracker rule lists for a page: none when blocking is off or the site is on the exemption list.
    func ruleLists(for url: URL?) -> [WKContentRuleList] {
        let settings = SettingsStore.shared
        guard settings.adBlockEnabled, !ProtectionPolicy.isExempt(host: url?.host, list: settings.protectionExemptHosts) else { return [] }
        return contentBlocker.ruleLists
    }

    var settingsReactionWork: DispatchWorkItem?

    /// Many defaults are written in a burst (saving the session writes several): react once, shortly after.
    func scheduleSettingsReaction() {
        settingsReactionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.applyRuleListsIfSettingsChanged()
                let font = CGFloat(SettingsStore.shared.minimumFontSize)
                for tab in self?.tabs ?? [] where tab.webView?.configuration.preferences.minimumFontSize != font { tab.webView?.configuration.preferences.minimumFontSize = font }
                self?.settingsChanged()
            }
        }
        settingsReactionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func applyRuleLists() {
        for tab in tabs { tab.applyContentRuleLists(ruleLists(for: tab.currentURL)) }
    }

    var lastBlockingSettings: [String] = []

    /// Re-applies the rule lists only when what decides them changed (the toggle, the exemption list) —
    /// not on every write to UserDefaults, which would also undo the per-site exemptions.
    func applyRuleListsIfSettingsChanged() {
        let current = ["\(SettingsStore.shared.adBlockEnabled)"] + SettingsStore.shared.protectionExemptHosts
        guard current != lastBlockingSettings else { return }
        lastBlockingSettings = current
        applyRuleLists()
    }

    // MARK: - Security & privacy (Phase 3)

    /// Scripts injected into a page: fingerprint protection (all pages) and,
    /// when ad blocking is on, the cosmetic CSS matching this URL.
    func userScripts(for url: URL?) -> [WKUserScript] {
        var scripts: [WKUserScript] = [CredentialScript.makeUserScript(), MediaScript.makeUserScript()]
        if SettingsStore.shared.sendGlobalPrivacyControl { scripts.append(PrivacyTools.gpcUserScript()) }
        if SettingsStore.shared.resumeEnabled { scripts.append(ResumeScript.makeUserScript()) }
        scripts.append(BoostScript.makeUserScript(boostConfig()))
        if SettingsStore.shared.nightMode != .off { scripts.append(NightScript.makeUserScript(nightConfig())) }
        if SettingsStore.shared.cleanCopy { scripts.append(CleanCopyScript.makeUserScript(addSource: SettingsStore.shared.copyAddsSource)) }
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
    var lastNight = [] as [String]
    var lastCopySettings = [SettingsStore.shared.cleanCopy, SettingsStore.shared.copyAddsSource, SettingsStore.shared.resumeEnabled]
    var lastShortcutOverrides = SettingsStore.shared.shortcutOverrides
    var lastLook = LookProfile.capture(named: "", from: SettingsStore.shared)
    var lastSidebarPrefs = [SettingsStore.shared.sidebarWidth, SettingsStore.shared.sidebarGlass ? 1 : 0]

    func settingsChanged() {
        if SettingsStore.shared.chromeLayout != appliedChromeLayout { applyChromeLayout() }
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
        let boosts = boostSignature()
        if boosts != lastBoostSignature { lastBoostSignature = boosts; refreshBoosts() }
        let night = nightSignature()
        if night != lastNight { lastNight = night; refreshNightMode() }
        let copySettings = [SettingsStore.shared.cleanCopy, SettingsStore.shared.copyAddsSource, SettingsStore.shared.resumeEnabled]
        if lastFingerprintSetting != fingerprint || lastLongPagesSetting != longPages || lastCopySettings != copySettings {
            lastFingerprintSetting = fingerprint
            lastLongPagesSetting = longPages
            lastCopySettings = copySettings
            for tab in tabs { tab.setUserScripts(userScripts(for: tab.currentURL)) }
        }
        refreshSafeBrowsing()
        let inspectable = SettingsStore.shared.webInspectorEnabled
        for tab in tabs { tab.setInspectable(inspectable) }
    }

    /// Creates (or drops) the Safe Browsing client to match the settings.
    /// Opt-in: with the setting off, no list is downloaded and no URL data leaves the machine.
    func refreshSafeBrowsing() {
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

    func permissionOrigin(_ origin: WKSecurityOrigin) -> String {
        origin.port > 0 ? "\(origin.protocol)://\(origin.host):\(origin.port)" : "\(origin.protocol)://\(origin.host)"
    }

    /// Decides camera/mic/location access: a remembered choice wins, otherwise
    /// ask. Private tabs neither read nor write the permission store.
    func decidePermission(_ kinds: [SitePermission], origin: WKSecurityOrigin, webView: WKWebView) async -> WKPermissionDecision {
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

    func showUnsafeSiteWarning(_ threat: ThreatKind, url: URL, in tab: Tab) {
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
    func makeFloatingCard(_ inner: NSView, cornerRadius: CGFloat) -> NSView {
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
    func buildUI() {
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
        toggleSidebarButton.onClick = { [weak self] in
            if self?.isMini == true { self?.moveMiniToMainWindow() } else { self?.toggleSidebar() }
        }
        customizeButton.onClick = { [weak self] in self?.openCustomize() }
        moreButton.onClick = { [weak self] in self?.openPalette(initialText: "", selectAll: false, opensInNewTab: true) }
        addressPill.onClick = { [weak self] in self?.focusAddressBar() }
        addressPill.onIconClick = { [weak self] in self?.showSiteInfo() }
        addressPill.onComplete = { [weak self] typed in self?.inlineCompletion(for: typed) }
        let bar = ToolbarView(pill: addressPill)
        toolbar = bar
        splitButton.onClick = { [weak self] in self?.toggleSplit() }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.settingsChanged() }
        }
        digestButton.onClick = { [weak self] in self?.digestAction() }
        calendarButton.onClick = { [weak self] in self?.addToCalendarAction() }
        nightButton.onClick = { [weak self] in self?.toggleNightForCurrentSite() }
        translateButton.onClick = { [weak self] in self?.translatePageAction() }
        downloadsButton.onClick = { [weak self] in self?.toggleDownloads() }
        downloads.onChange = { [weak self] in self?.downloadsChanged() }
        downloads.onFinish = { [weak self] in self?.downloadsButton.pulse() }
        downloads.onFinishedFile = { [weak self] file in self?.offerExtensionInstall(fromFile: file) }
        downloads.onStart = { [weak self] in
            guard let self else { return }
            self.downloadsButton.pulse()
            // Show the list (once, if it isn't open yet) so the user sees the download begin.
            if self.downloadsPopover?.isShown != true { self.toggleDownloads() }
        }
        downloads.resumeWebView = { [weak self] in self?.activeTab?.webView }
        downloads.start()
        assistantButton.onClick = { [weak self] in self?.askAIAction() }
        applyChromeLayout()

        // Page sheet: top-left corner rounded, flush against the right and bottom edges.
        contentContainer.cornerRadius = Theme.pageCornerRadius
        contentContainer.maskedCorners = [.layerMinXMaxYCorner]
        contentContainer.clips = true
        contentContainer.addSubview(loadingBar)
        contentContainer.addSubview(digestPanel)
        NSLayoutConstraint.activate([
            digestPanel.topAnchor.constraint(equalTo: contentContainer.topAnchor), digestPanel.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            digestPanel.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor), digestPanel.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])
        digestPanel.onClose = { [weak self] byUser in
            guard let self else { return }
            self.digestTask?.cancel(); self.digestTask = nil
            if byUser, let key = self.digestKey { self.digestDismissed.insert(key) }       // closed on purpose: not reopened by itself on this page
            self.digestKey = nil
            if let tab = self.activeTab { self.updateDigestButton(for: tab) }
        }
        contentContainer.addSubview(webPanel)
        NSLayoutConstraint.activate([
            webPanel.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 10), webPanel.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -10),
            webPanel.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -10),
        ])
        webPanel.onOpenInTab = { [weak self] url in self?.newTab(urlString: url.absoluteString, isPrivate: false) }
        contentContainer.addSubview(peekPanel)
        NSLayoutConstraint.activate([
            peekPanel.topAnchor.constraint(equalTo: contentContainer.topAnchor), peekPanel.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            peekPanel.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor), peekPanel.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])
        peekPanel.onOpenInTab = { [weak self] url in self?.newTab(urlString: url.absoluteString, isPrivate: self?.activeTab?.isPrivate ?? false) }
        peekPanel.onOpenInMini = { [weak self] url in self?.openMiniWindow(url: url) }
        contentContainer.addSubview(noticePill)
        readingBar.fill = Theme.accent
        readingBar.isHidden = true
        contentContainer.addSubview(readingBar)
        let barWidth = readingBar.widthAnchor.constraint(equalToConstant: 0)
        readingBarWidth = barWidth
        NSLayoutConstraint.activate([
            readingBar.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            readingBar.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            readingBar.heightAnchor.constraint(equalToConstant: 2), barWidth,
        ])
        audioRoute.onChange = { [weak self] in self?.refreshNowPlaying() }
        audioRoute.start()
        NSLayoutConstraint.activate([
            noticePill.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            noticePill.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -24),
        ])
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
        tabStrip.overflowButton.onClick = { [weak self] in self?.showAllTabsMenu() }
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
            contentContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        let pageEdge = contentContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        pageEdge.isActive = true
        pageTrailing = pageEdge

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
    func buildSidebar() -> NSView {
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
        footerStack = panelBar
        footerTail = [spacer, sleepMetaLabel]
        applyChromeLayout()

        [topStack, searchRow, newTabRow, scroll, sidePanel, nowPlaying, panelBar].forEach(column.addSubview)
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
            scroll.bottomAnchor.constraint(equalTo: nowPlaying.topAnchor),
            nowPlaying.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: rowsInset),
            nowPlaying.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -rowsInset),
            nowPlaying.bottomAnchor.constraint(equalTo: panelBar.topAnchor, constant: -6),

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

    func togglePanel(_ kind: PanelKind?) {
        activePanel = (kind == activePanel) ? nil : kind
        refreshPanel()
    }

    /// Shows the chosen panel in place of the tab list (or brings the tabs back).
    func refreshPanel() {
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

    func downloadsChanged() {
        if activePanel == .downloads { refreshPanel() }
        let summary = downloads.summary
        setRelevant(.downloads, downloads.hasItems)
        downloadsButton.ringIndeterminate = summary.running > 0 && summary.fraction == nil
        downloadsButton.ringProgress = summary.running > 0 && summary.fraction != nil ? summary.fraction : nil
        let tip = summary.running > 0 ? "Téléchargements — \(summary.running) en cours · \(ByteFormat.speed(summary.bytesPerSecond))" : "Téléchargements"
        downloadsButton.toolTip = tip
        downloadsButton.setAccessibilityLabel(tip + (summary.fraction.map { ", \(Int($0 * 100)) %" } ?? ""))
        downloadsPanel?.refresh()
        if let popover = downloadsPopover, popover.isShown, let panel = downloadsPanel { popover.contentSize = panel.frame.size }
    }

    func toggleDownloads() {
        if let popover = downloadsPopover, popover.isShown { popover.close(); return }
        let popover = NSPopover()
        popover.behavior = .transient
        let panel = DownloadsPanelView(controller: downloads)
        let controller = NSViewController()
        controller.view = panel
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: DownloadsPanelView.width, height: panel.frame.height)
        guard showPopoverSafely(popover, relativeTo: downloadsButton, fallback: addressPill) else { return }
        downloadsPopover = popover
        downloadsPanel = panel
    }

    // MARK: - Split screen

    func splitContains(_ id: UUID) -> Bool { splitPair.map { $0.left == id || $0.right == id } ?? false }

    /// A tab shown in the split screen but not focused is still on screen: never put it to sleep.
    func isOnScreen(_ tab: Tab) -> Bool { tab.id == activeTabID || splitContains(tab.id) }

    func ensureAwake(_ tab: Tab) {
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

    func beginSplit(left: Tab, right: Tab) {
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
    func installSplitLayout() {
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

    func refreshSplitHeaders() {
        guard splitPair != nil else { return }
        for (id, header) in splitHeaders {
            guard let tab = tabs.first(where: { $0.id == id }) else { continue }
            header.configure(title: tab.displayTitle, host: tab.badgeHost)
            header.isFocused = id == activeTabID
        }
        splitHinge?.ratio = splitRatio
    }

    func setSplitRatio(_ ratio: CGFloat, animated: Bool) {
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

    func swapSplit() {
        guard let pair = splitPair else { return }
        splitPair = (pair.right, pair.left)
        installSplitLayout()
        saveSession()
    }

    /// Back to a single page. `keeping` is the tab that stays visible (nil = the focused one).
    func endSplit(keeping id: UUID?) {
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
    func focusPane(at event: NSEvent) {
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
    public static func purgeSnapshots() { Tab.purgeSnapshots(); GhostStorage.purge() }

    /// At quit: keeps (encrypted) what each open, non-private tab looks like, so that on the next launch a tab that wakes does not show a
    /// blank page while it loads. Whatever belongs to a tab that is no longer open is deleted.
    public func persistSleepSnapshots() {
        guard !isFreshSession else { return }
        var kept = Set<String>()
        for tab in tabs where SessionPolicy.isSavable(url: tab.currentURL, isPrivate: tab.isPrivate) {
            guard let address = tab.currentURL?.absoluteString else { continue }
            kept.insert(address)
            if let picture = tab.pictureForNextLaunch { try? SnapshotVault.shared.put(picture, for: address) }
        }
        SnapshotVault.shared.prune(keeping: kept)
    }

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

    func closeOverview() {
        overview.dismiss()
        if let webView = activeTab?.webView { window?.makeFirstResponder(webView) }
    }

    func overviewCards() -> [SpaceCardData] {
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
    func deleteSpace(_ index: Int) {
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

    func closeCustomize() {
        drawer.dismiss()
        if let webView = activeTab?.webView { window?.makeFirstResponder(webView) }
    }

    func pickHomePhoto() {
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
    func applyLookChanges() {
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
    func reloadHomePages() {
        for tab in tabs where tab.webView?.url?.scheme == "oree" {
            tab.webView?.loadHTMLString(StartPage.render(homeInput(for: tab)), baseURL: StartPage.baseURL)
        }
    }

    // MARK: - Sidebar modes

    /// What is actually shown: the chosen mode, except that narrow windows fall back to compact.
    var effectiveSidebarMode: SidebarMode {
        isMini ? .hidden : BrowserCore.effectiveSidebarMode(SettingsStore.shared.sidebarMode, windowWidth: Double(window?.frame.width ?? 1280))
    }

    /// Width of the expanded sidebar (user-resizable by dragging its right edge).
    var expandedSidebarWidth: CGFloat { CGFloat(SettingsStore.shared.sidebarWidth) }

    func applySidebarMode(animated: Bool) {
        let store = SettingsStore.shared
        let horizontal = store.tabLayout == .horizontal && !isMini
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
        let showToggle = isMini || (!horizontal && (hidden || hover || store.sidebarMode == .compact))
        setRelevant(.sidebarToggle, showToggle)
        if !isMini { toggleSidebarButton.toolTip = compact ? "Agrandir la barre latérale  ⌥⌘S" : "Afficher la barre latérale  ⌥⌘S" }
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
    func refreshHoverSpaceRow() {
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
    func resizeSidebar(toRight x: CGFloat, final: Bool) {
        guard let sidebar = sidebarView else { return }
        let left = sidebar.frame.minX
        let width = CGFloat(SidebarWidth.clamp(Double(x - left)))
        sidebarWidth?.constant = width
        if !effectiveSidebarMode.overlaysPage { mainLeading?.constant = width }
        window?.contentView?.layoutSubtreeIfNeeded()
        if final { SettingsStore.shared.sidebarWidth = Double(width) }
    }

    // MARK: Hover sidebar

    var pointerInSidebar: Bool {
        guard let window, let sidebar = sidebarView, let content = window.contentView else { return false }
        let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return sidebar.frame.insetBy(dx: -4, dy: -4).contains(point)
    }

    var pointerInEdgeZone: Bool {
        guard let window, let content = window.contentView else { return false }
        let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return edgeTrigger.frame.insetBy(dx: -2, dy: 0).contains(point)
    }

    /// The pointer touched the left edge: show the panel if it is still there after a short moment (not when merely passing by).
    func scheduleFloatingShow() {
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
    func scheduleFloatingHide(after delay: TimeInterval) {
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
    func setFloatingShown(_ shown: Bool) {
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
    func toggleCompactSidebar() {
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
    var demoPanel: DownloadsPanelView?
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
    public func windowDidEnterFullScreen(_ notification: Notification) { settleLayout() }
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
        settleLayout()
    }

    public func windowDidResize(_ notification: Notification) {
        applySidebarMode(animated: false)
        if windowExceedsScreen() { DispatchQueue.main.async { [weak self] in self?.clampWindowToScreen() } }
    }

    public func windowDidChangeScreen(_ notification: Notification) { settleLayout() }

    // MARK: Retour du plein écran : tout remettre d'aplomb

    /// AppKit finit d'attacher la barre de titre et de rendre ses dimensions à la fenêtre un peu après `windowDidExitFullScreen` : le mode compact
    /// (rail, décalage des boutons) et la page doivent être recalculés une fois la transition vraiment terminée, pas seulement à son annonce.
    func settleLayout() {
        relayoutWindow()
        for delay in [0.12, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.relayoutWindow() }
        }
    }

    func relayoutWindow() {
        clampWindowToScreen()
        applySidebarMode(animated: false)
        contentContainer.needsLayout = true
        window?.contentView?.layoutSubtreeIfNeeded()
        activeTab?.webView?.needsLayout = true
    }

    func windowExceedsScreen() -> Bool {
        guard let window, !window.styleMask.contains(.fullScreen), !isFullScreen, let visible = window.screen?.visibleFrame else { return false }
        return window.frame.width > visible.width + 1 || window.frame.height > visible.height + 1
    }

    /// Une fenêtre ne doit jamais être plus grande que l'écran qui la porte (une page qui impose une largeur, un retour du plein écran mal
    /// terminé, un écran débranché…) : sinon la page déborde et on ne peut plus attraper les bords.
    func clampWindowToScreen() {
        guard windowExceedsScreen(), let window, let visible = window.screen?.visibleFrame else { return }
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
        window.setFrame(frame, display: true)
    }

    @objc func automationHugeWindow() {
        guard var frame = window?.frame else { return }
        frame.size.width = 6000
        window?.setFrame(frame, display: true)
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

    func makeFavoriteMenu(for bookmark: Bookmark) -> NSMenu {
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
    func isEligibleForCredentials(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host else { return false }
        if url.scheme == "https" { return true }
        return url.scheme == "http" && (host == "localhost" || host == "127.0.0.1")
    }

    func handleCredentialMessage(webView: WKWebView, origin: String, body: [String: Any]) {
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

    func offerAutofill(in tab: Tab, webView: WKWebView, origin: String) async {
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
            _ = await webView.safeCall("return window.__hbFill(u, p);", arguments: ["u": login.username, "p": password], world: .page)
        } catch {
            Log.security.error("Autofill failed: \(String(describing: error), privacy: .public)")
        }
    }

    func chooseLogin(_ logins: [SavedLogin], host: String) async -> SavedLogin? {
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

    func offerToSave(origin: String, username: String, password: String) async {
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

    func refreshAddressSuggestions(_ query: String) {
        let sections = paletteSections(query: query.trimmingCharacters(in: .whitespacesAndNewlines), filter: .all)
            .filter { $0.title != "Actions" && $0.title != "Espaces" && $0.title != "Favoris" }
        addressDropdown.show(sections)
    }

    /// What the address bar can finish `typed` with, from the favorites and the history (most visited first).
    func inlineCompletion(for typed: String) -> String? {
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { return nil }
        let favorites = ((try? bookmarkRepo.all()) ?? []).map(\.url)
        let visited = (try? historyRepo.addresses(containing: text.components(separatedBy: "/").first ?? text)) ?? []
        return InlineCompletion.completion(for: typed, candidates: favorites + visited)
    }

    func endAddressEditing() {
        addressPill.endEditing()
        addressDropdown.hide()
        if let webView = activeTab?.webView, window?.firstResponder is NSText || window?.firstResponder === window { window?.makeFirstResponder(webView) }
    }

    func commitAddress(_ text: String, newTab: Bool) {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Like the palette: Return runs the highlighted suggestion (the first one unless arrowed).
        if let item = addressDropdown.selectedItem, addressDropdown.hasSelection, !raw.isEmpty {
            endAddressEditing(); item.perform(newTab); return
        }
        endAddressEditing()
        guard !raw.isEmpty else { return }
        openFromPalette(raw, inNewTab: newTab)
    }

    func openPalette(initialText: String, selectAll: Bool, opensInNewTab: Bool) {
        palette.present(initialText: initialText, selectAll: selectAll, opensInNewTab: opensInNewTab, in: window)
    }

    func closePalette() {
        palette.dismiss(restoringFocusTo: activeTab?.webView)
    }

    func openFromPalette(_ raw: String, inNewTab: Bool) {
        if inNewTab || activeTab == nil {
            newTab(urlString: raw, isPrivate: SettingsStore.shared.privateByDefault)
        } else if let tab = activeTab {
            load(urlString: raw, in: tab)
        }
    }

    func paletteSections(query: String, filter: PaletteFilter) -> [PaletteSection] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ values: String...) -> Bool {
            q.isEmpty || values.contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        var sections: [PaletteSection] = []

        if filter == .all, let value = Calculator.evaluate(q) {
            let answer = Calculator.format(value)
            sections.append(PaletteSection(title: "Calcul", items: [
                PaletteItem(icon: .symbol("equal.square"), title: "= \(answer)", subtitle: q, trailing: "↵ copier", perform: { [weak self] _ in
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(answer, forType: .string)
                    self?.presentNotice("« \(answer) » copié.")
                }),
            ]))
        }

        if filter == .all, !q.isEmpty {
            let resolution = AddressResolver.resolve(q, defaultEngine: SettingsStore.shared.searchEngine, custom: SettingsStore.shared.customSearchShortcuts)
            var siteName: String?
            if case .search(let site, _)? = resolution { siteName = site }
            let isAddress = siteName == nil
            sections.append(PaletteSection(title: isAddress ? "Ouvrir" : "Rechercher", items: [
                PaletteItem(
                    icon: .symbol(isAddress ? "arrow.up.right" : "magnifyingglass"),
                    title: isAddress ? q : "« \(q) » sur \(siteName ?? "le web")",
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
            var actions: [(String, String, @MainActor (BrowserWindowController) -> Void)] = [
                ("Écran partagé", "rectangle.split.2x1", { $0.toggleSplit() }),
                ("Ajouter à la liste de lecture", "text.book.closed", { if let tab = $0.activeTab { $0.addToReadingList(tab) } }),
                ("Afficher l'historique", "clock", { $0.openHistoryPanel() }),
                ("Gestionnaire de tâches", "gauge.with.dots.needle.33percent", { $0.showTaskManager() }),
                ("Personnaliser l'apparence", "paintbrush", { $0.openCustomize() }),
                ("Vue d'ensemble des espaces", "square.grid.2x2", { $0.openOverview() }),
                ("Mettre l'onglet en veille", "moon", { $0.sleepActiveTab() }),
                ("Nouvel onglet vide", "plus", { $0.newTab(urlString: nil, isPrivate: SettingsStore.shared.privateByDefault) }),
                ("Nouvel onglet privé", "lock.shield", { $0.newPrivateTabAction() }),
                ("Rouvrir l'onglet fermé", "arrow.uturn.backward", { $0.reopenClosedTab() }),
                ("Onglets archivés…", "archivebox", { $0.showArchiveMenu() }),
                ("Notes", "note.text", { $0.showNotes() }),
                ("Aller à l'espace suivant", "square.stack", { $0.selectNextSpace() }),
                ("Recharger la page", "arrow.clockwise", { $0.reloadAction() }),
                ("Ajouter ou retirer des favoris", "star", { if let tab = $0.activeTab { $0.toggleBookmark(for: tab) } }),
                ("Rechercher dans la page", "text.magnifyingglass", { $0.findInPage() }),
                ("Afficher ou masquer la barre latérale", "sidebar.left", { $0.toggleSidebar() }),
                ("Fermer l'onglet", "xmark", { $0.closeActiveTabAction() }),
                ("Réglages", "gearshape", { $0.openSettings() }),
            ]
            if let host = activeTab?.webView?.url?.host, activeTab?.webView?.url?.scheme?.hasPrefix("http") == true {
                let asChrome = SettingsStore.shared.chromeUserAgentHosts.contains { UserAgent.hostMatches(host, listed: $0) }
                actions.append((asChrome ? "Se présenter comme Safari sur ce site" : "Se présenter comme Chrome sur ce site", "person.crop.circle.badge.questionmark", { $0.toggleChromeAgentForCurrentSite() }))
            }
            if activeTab?.webView?.url?.scheme?.hasPrefix("http") == true {
                actions.append((activeTab?.readerOrigin == nil ? "Mode lecture" : "Quitter le mode lecture", "text.book.closed", { $0.toggleReaderMode() }))
            }
            if let host = activeTab?.webView?.url?.host, activeTab?.webView?.url?.scheme?.hasPrefix("http") == true {
                let mobile = SettingsStore.shared.mobileSiteHosts.contains { UserAgent.hostMatches(host, listed: $0) }
                actions.append((mobile ? "Demander la version ordinateur de ce site" : "Demander la version mobile de ce site", "iphone", { $0.toggleMobileForCurrentSite() }))
                actions.append(("Lire la page à voix haute", "speaker.wave.2", { $0.readPageAloud() }))
                actions.append(("Partager la page…", "square.and.arrow.up", { $0.sharePage() }))
            }
            if PageTranslator.isAvailable, TranslationPolicy.canTranslate(url: activeTab?.webView?.url) {
                let showing = activeTab?.translator.state != .idle
                actions.append((showing ? "Afficher la page d'origine" : "Traduire la page", "translate", { $0.translatePageAction() }))
            }
            if TranslationPolicy.canTranslate(url: activeTab?.webView?.url) {
                actions.append((digestPanel.state == "closed" ? "L'essentiel" : "Fermer « L'essentiel »", "list.bullet.clipboard", { $0.digestAction() }))
            }
            actions.append(("Demander à l'IA", "sparkles", { $0.askAIAction() }))
            actions.append(contentsOf: webPanelActions())
            if TranslationPolicy.canTranslate(url: activeTab?.webView?.url) {
                actions.append(("Ajouter au Calendrier", "calendar.badge.plus", { $0.addToCalendarAction() }))
                actions.append(("Personnaliser ce site…", "wand.and.stars", { $0.customizeSiteAction() }))
                let boost = try? boostRepo.boost(for: activeTab?.webView?.url?.host)
                if boost?.rules.isEmpty == false { actions.append(("Retirer les changements de ce site", "arrow.uturn.backward.circle", { $0.removeBoostAction() })) }
                actions.append((boost?.calm == true ? "Mode calme : le quitter sur ce site" : "Mode calme sur ce site", "leaf", { $0.toggleCalmForSiteAction() }))
            }
            let night = SettingsStore.shared.nightMode
            for (mode, title) in [(NightMode.always, "Mode nuit : toujours"), (.auto, "Mode nuit : automatique (suit le Mac)"), (.off, "Mode nuit : désactivé")] where mode != night {
                actions.append((title, "moon", { $0.setNightMode(mode) }))
            }
            if night != .off, TranslationPolicy.canTranslate(url: activeTab?.webView?.url) {
                actions.append(("Mode nuit : ce site clair ou sombre", "moon.circle", { $0.toggleNightForCurrentSite() }))
            }
            if PageTranslator.isAvailable, activeTab?.translator.pageLanguage.map({ $0 != "und" }) == true {
                actions.append(("Télécharger la traduction rapide", "arrow.down.circle", { $0.downloadFastTranslationAction() }))
            }
            let found = actions.filter { matches($0.0) }
            sections.append(PaletteSection(title: "Actions", items: found.prefix(filter == .all && q.isEmpty ? 4 : 12).map { action in
                PaletteItem(icon: .symbol(action.1), title: action.0, subtitle: nil, trailing: nil,
                            perform: { [weak self] _ in if let self { action.2(self) } })
            }))
        }
        return sections
    }

    /// Whether typed text should be opened as an address rather than searched.
    static func looksLikeAddress(_ text: String) -> Bool { AddressResolver.looksLikeAddress(text) }

    func buildFindBar(in contentView: NSView) {
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

    func makeConfiguration(isPrivate: Bool) -> WKWebViewConfiguration {
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
        config.userContentController.addUserScript(MediaScript.makeUserScript())
        if SettingsStore.shared.sendGlobalPrivacyControl { config.userContentController.addUserScript(PrivacyTools.gpcUserScript()) }
        config.preferences.minimumFontSize = CGFloat(SettingsStore.shared.minimumFontSize)
        if SettingsStore.shared.resumeEnabled { config.userContentController.addUserScript(ResumeScript.makeUserScript()) }
        config.userContentController.addUserScript(BoostScript.makeUserScript(boostConfig()))
        if SettingsStore.shared.lightLongPages {
            config.userContentController.addUserScript(LongPageScript.makeUserScript())
        }
        config.userContentController.add(credentialHandler, name: CredentialScript.handlerName)
        config.setURLSchemeHandler(oreeSchemeHandler, forURLScheme: "oree")
        // Extensions run in normal tabs only, never in private ones.
        if !isPrivate { config.webExtensionController = extensionManager.controller }
        return config
    }

    func attachTab(_ tab: Tab) {
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
        tab.ghostRuleLists = { [weak self, weak tab] in self?.ruleLists(for: tab?.currentURL) ?? [] }
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
        tab.tabButton.onHoverPreview = { [weak self, weak tab] hovering in
            guard let self, let tab else { return }
            if hovering { self.showTabPreview(for: tab) } else { self.hideTabPreview(of: tab) }
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
    func recoverFromCrash(_ tab: Tab) {
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
    func homeInput(for tab: Tab) -> HomeInput {
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
    func handleHomeAction(_ url: URL) {
        switch url.host {
        case "space": if let index = Int(url.lastPathComponent) { selectSpace(index) }
        case "customize": openSettings()
        default: break
        }
    }

    /// The card under the pointer: a picture of the page, its title and site, and its state or memory. Never for the tab in front.
    func showTabPreview(for tab: Tab) {
        guard SettingsStore.shared.tabPreviews, tab.id != activeTabID, window?.isKeyWindow == true || ProcessInfo.processInfo.environment["HB_FRESH_SESSION"] != nil else { return }
        tabPreviewTask?.cancel()
        tabPreviewTask = Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            let image = await tab.previewImage()
            guard !Task.isCancelled, tab.tabButton.window != nil, tab.id != self.activeTabID else { return }
            let row = self.taskManagerSnapshot().snapshot.rows.first { $0.id == tab.id }
            let status: String
            switch row?.state {
            case .sleeping?: status = "En veille"
            case .frozen?: status = "Figé · " + TaskManagerRows.memory(row?.bytes ?? 0)
            case .audio?: status = "Joue du son · " + TaskManagerRows.memory(row?.bytes ?? 0)
            case .some(let state) where (row?.bytes ?? 0) > 0: status = state.rawValue + " · " + TaskManagerRows.memory(row?.bytes ?? 0)
            default: status = ""
            }
            self.tabPreviewPopover?.close()
            let controller = NSViewController()
            controller.view = TabPreviewCard(image: image, title: tab.displayTitle, host: tab.badgeHost, status: status)
            let popover = NSPopover()
            popover.behavior = .applicationDefined; popover.animates = false; popover.contentViewController = controller
            let horizontal = SettingsStore.shared.tabLayout == .horizontal
            if self.showPopoverSafely(popover, relativeTo: tab.tabButton, edge: horizontal ? .minY : .maxX) { self.tabPreviewPopover = popover }
        }
    }

    func hideTabPreview(of tab: Tab? = nil) {
        tabPreviewTask?.cancel()
        tabPreviewPopover?.close()
        tabPreviewPopover = nil
    }

    /// ⌃Tab — back to the tab used before this one (again: back to this one).
    @objc func selectRecentTab() {
        guard let previous = recentTabIDs.dropFirst().compactMap({ id in tabs.first { $0.id == id } }).first else { NSSound.beep(); return }
        selectTab(previous)
    }

    func selectTab(_ tab: Tab) {
        recentTabIDs.removeAll { $0 == tab.id }
        recentTabIDs.insert(tab.id, at: 0)
        if recentTabIDs.count > 50 { recentTabIDs.removeLast() }
        aiBarController?.tabChanged(id: tab.id, title: tab.displayTitle)
        if peekPanel.isShown { peekPanel.close() }
        if digestPanel.state != "closed" { digestPanel.close() }     // the essentials belong to the page they were made from
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
        if SettingsStore.shared.tabLayout == .horizontal, tab.tabButton.superview === tabStrip.tabsStack { tabStrip.activeTabView = tab.tabButton; tabStrip.needsLayout = true }
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
        loadingBar.update(progress: tab.showsLoading ? (tab.webView?.estimatedProgress ?? 0) : 0, isLoading: tab.showsLoading)
        if let webView = tab.webView {
            window?.makeFirstResponder(webView)
        }
    }

    func closeTab(_ tab: Tab, remember: Bool = true) {
        aiBarController?.tabClosed(tab.id)
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if let pair = splitPair, tab.id == pair.left || tab.id == pair.right {
            endSplit(keeping: tab.id == pair.left ? pair.right : pair.left)
        }
        extensionManager.tabClosed(tab)
        if remember, !tab.isPrivate, let url = tab.currentURL {
            closedTabs.append((url, tab.currentInteractionState, tab.displayTitle, tab.spaceIndex))
            if closedTabs.count > 20 { closedTabs.removeFirst() }
        }
        tab.contentSlot.removeFromSuperview()
        tab.tearDown()
        tabs.remove(at: idx)
        updateTabCount()
        let button = tab.tabButton
        // The rows below spring up into the gap once the closed row has gone.
        let container = button.superview as? NSStackView
        button.animateOut { [weak self] in
            guard let self else { return }
            let before = TabMotion.visualFrames(of: container?.arrangedSubviews ?? [])
            self.rebuildTabList()
            button.removeFromSuperview()
            container?.layoutSubtreeIfNeeded()
            self.tabStrip.layoutSubtreeIfNeeded()
            TabMotion.reflow(container?.arrangedSubviews ?? [], from: before)
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
    func moveActiveTab(by offset: Int) {
        guard let tab = activeTab else { return }
        moveTab(tab, by: offset)
    }

    /// Moves `tab` by `offset` rows (clamped), in both the model and the sidebar.
    func moveTab(_ tab: Tab, by offset: Int) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }),
              let newIndex = TabSelection.destinationIndex(of: idx, offset: offset, spaces: tabs.map(\.spaceIndex)) else { return }

        // Every row springs from where it is on screen (a dragged row: under the pointer) to its new slot.
        let container = tab.tabButton.superview as? NSStackView
        let before = TabMotion.visualFrames(of: container?.arrangedSubviews ?? [])
        tabs.remove(at: idx)
        tabs.insert(tab, at: newIndex)
        rebuildTabList()
        tabBarStack.superview?.layoutSubtreeIfNeeded()
        tabStrip.layoutSubtreeIfNeeded()
        TabMotion.reflow(container?.arrangedSubviews ?? [], from: before)
        saveSession()
    }

    // MARK: - Spaces

    func visibleTabs() -> [Tab] { tabs.filter { $0.spaceIndex == currentSpace } }

    /// Header of the tab column: "N onglets" (never mentions sleeping tabs: hibernation is invisible).
    func updateTabCount() {
        refreshNowPlaying()
        let mine = visibleTabs()
        let count = mine.count
        spaceMetaLabel.stringValue = "\(count) onglet\(count > 1 ? "s" : "")"
        sleepMetaLabel.stringValue = ""
        spaceRail.setTabs(mine.map { tab in
            (tab.displayTitle, tab.badgeHost, tab.id == activeTabID, tab.isSuspended,
             { [weak self, weak tab] in if let tab { self?.selectTab(tab) } })
        })
    }

    /// Brings the sidebar in line with `currentSpace`: rail, header, lisière, which tab rows are shown.
    func refreshSpaceUI(animated: Bool) {
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
    func rebuildTabList() {
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
        if !horizontal {
            // Right after the last tab, where the eye is when the list is long (the one at the top stays for the shortcut).
            let row = inlineNewTabRow ?? makeInlineNewTabRow()
            container.addArrangedSubview(row)
        }
        if horizontal {
            tabStrip.spaceChip.configure(currentSpaceStyle)
            tabStrip.activeTabView = activeTab?.tabButton
            tabStrip.tabsChanged()
        }
        updateTabCount()
    }

    /// The ▾ button of a full tab strip: every tab of this space, the one in front ticked; a pick brings it to the front.
    func showAllTabsMenu() {
        let menu = NSMenu()
        for tab in tabs where tab.spaceIndex == currentSpace {
            let item = ClosureMenuItem(title: tab.displayTitle.isEmpty ? (tab.badgeHost.isEmpty ? "Nouvel onglet" : tab.badgeHost) : tab.displayTitle) { [weak self, weak tab] in if let tab { self?.selectTab(tab) } }
            item.state = tab.id == activeTabID ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: tabStrip.overflowButton.bounds.height + 4), in: tabStrip.overflowButton)
    }

    var inlineNewTabRow: SidebarRowView?
    func makeInlineNewTabRow() -> SidebarRowView {
        let row = SidebarRowView(symbol: "plus", title: "Nouvel onglet", shortcut: nil)
        row.onClick = { [weak self] in self?.newTabAction() }
        row.setAccessibilityLabel("Nouvel onglet")
        inlineNewTabRow = row
        return row
    }

    func toggleGroup(_ id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].collapsed.toggle()
        Motion.animate(Motion.standard) { rebuildTabList(); tabBarStack.superview?.layoutSubtreeIfNeeded() }
        saveSession()
    }

    func makeGroupMenu(for id: UUID) -> NSMenu {
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

    func promptForText(title: String, button: String, initial: String, completion: @escaping @MainActor (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Annuler")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            MainActor.assumeIsolated { completion(String(text.prefix(30))) }
        }
    }

    func renameGroup(_ id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        promptForText(title: "Renommer le groupe", button: "Renommer", initial: groups[index].name) { [weak self] name in
            guard let self, let i = self.groups.firstIndex(where: { $0.id == id }) else { return }
            self.groups[i].name = name
            self.rebuildTabList()
            self.saveSession()
        }
    }

    func dissolveGroup(_ id: UUID) {
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

    func setCurrentSpace(_ index: Int, animated: Bool) {
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

    func startMemoryBudgetTimer() {
        memoryBudgetTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.enforceMemoryBudget() }
        }
    }

    /// Fraction of the budget the last pass found in use; pre-waking is skipped while over budget.
    var isOverBudget = false

    func memoryBudgetBytes() -> UInt64? {
        let setting = SettingsStore.shared.memoryBudgetMB
        guard setting >= 0 else { return nil }
        return setting == 0 ? MemoryBudget.automaticBudgetBytes() : UInt64(setting) * 1_048_576
    }

    /// One pass of the tab lifecycle, every 20 s (awake → frozen → asleep, see `TabLifecyclePolicy`):
    ///  1. hidden tabs: after a minute out of sight, clean their JavaScript memory (once per absence);
    ///  2. over budget: first clean (cheap, nothing is lost), and only if that isn't enough, apply the plan;
    ///  3. the plan freezes tabs hidden for a while and sleeps the ones hidden very long or, when over
    ///     budget, the best-scoring ones down to 80 % of the budget.
    var isLifecyclePassRunning = false

    func enforceMemoryBudget() async {
        // Two timers call this and a pass awaits (media checks, a 4 s pause): never run two at once.
        guard !isLifecyclePassRunning else { return }
        isLifecyclePassRunning = true
        defer { isLifecyclePassRunning = false }
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

    func lifecycleTiming() -> TabLifecyclePolicy.Timing {
        var sleepAfter = TimeInterval(SettingsStore.shared.autoSuspendMinutes * 60)
        // After a recent memory warning, be much less patient.
        if sleepAfter > 0, let last = lastMemoryPressure, Date().timeIntervalSince(last) < 600 { sleepAfter = min(sleepAfter, 180) }
        let timing = TabLifecyclePolicy.Timing(freezeAfter: TimeInterval(SettingsStore.shared.freezeAfterSeconds), sleepAfter: sleepAfter)
        return EnergyPolicy.adjusted(timing, active: EnergyPolicy.isActive(mode: SettingsStore.shared.energyMode, systemLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled))
    }

    /// Why a tab may or may not be touched: on screen, playing sound, using camera/mic, a messaging
    /// or "never sleep" site → left alone; unsaved input → frozen but never torn down.
    func lifecycleExemption(of tab: Tab) async -> TabLifecyclePolicy.Exemption {
        if isOnScreen(tab) || tab.isCapturingMedia || tab.isInFullscreen || tab.audioState == .playing { return .full }
        if SleepExemptions.isExempt(host: tab.currentURL?.host, userHosts: SettingsStore.shared.neverSleepHosts) { return .full }
        if await tab.isPlayingMedia() { return .full }
        return tab.isDirty ? .noSleep : .none
    }

    func lifecyclePlan(reading: MemoryReading, budget: UInt64, timing: TabLifecyclePolicy.Timing) async -> TabLifecyclePolicy.Plan {
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
    func apply(_ plan: TabLifecyclePolicy.Plan, captureGhost: Bool = true) async -> Int {
        for id in plan.freeze { tabs.first { $0.id == id }?.freeze() }
        var slept = 0
        for id in plan.sleep {
            guard let tab = tabs.first(where: { $0.id == id }), !isOnScreen(tab) else { continue }
            await tab.suspend(captureGhost: captureGhost)
            slept += 1
        }
        return slept
    }

    /// Puts the best-scoring hidden tabs to sleep until the total should fit `target` (the active tab,
    /// sound/camera tabs and tabs with unsaved input are never torn down). Returns how many slept.
    func sleepTabs(toReach target: UInt64, reading: MemoryReading, minimumIdle: Double) async -> Int {
        let timing = TabLifecyclePolicy.Timing(freezeAfter: 0, sleepAfter: 0, minimumIdle: minimumIdle, hysteresis: 1)
        var plan = await lifecyclePlan(reading: reading, budget: target, timing: timing)
        plan.freeze = []
        return await apply(plan)
    }

    // MARK: Learned site profiles

    func siteProfile(forHost host: String?) -> SiteProfile? {
        guard SettingsStore.shared.learnSiteMemory, let host else { return nil }
        if let cached = siteProfileCache[host] { return cached }
        let profile = try? siteMemoryRepo.profile(host: host)
        siteProfileCache[host] = .some(profile)
        return profile
    }

    /// Every pass, remember how much each open (non-private, settled) site is using.
    func recordSiteSamples(_ reading: MemoryReading) {
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
    func makeRoom(forNavigationTo url: URL, in tab: Tab) async {
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

    struct MemoryReading {
        var total: UInt64
        var bytesByProcess: [Int32: UInt64]
        var processOfTab: [UUID: Int32]
    }

    func measureTabMemory() -> MemoryReading {
        var bytesByProcess: [Int32: UInt64] = [:]
        var processOfTab: [UUID: Int32] = [:]
        for tab in tabs where tab.webView != nil {
            guard let pid = tab.webProcessID, let bytes = MemoryBudget.footprint(ofProcess: pid) else { continue }
            bytesByProcess[pid] = bytes
            processOfTab[tab.id] = pid
        }
        return MemoryReading(total: bytesByProcess.values.reduce(0, +), bytesByProcess: bytesByProcess, processOfTab: processOfTab)
    }

    /// What the task manager shows now: every tab of every window with what its page costs.
    func taskManagerSnapshot() -> (snapshot: TaskManagerRows.Snapshot, appBytes: UInt64?) {
        let reading = measureTabMemory()
        let infos = tabs.map { tab in
            TaskManagerRows.TabInfo(id: tab.id, title: tab.displayTitle, host: tab.badgeHost, processID: tab.webView == nil ? nil : reading.processOfTab[tab.id],
                                    isSleeping: tab.isSuspended, isFrozen: tab.isFrozen, playsAudio: tab.audioState == .playing, isActive: tab.id == activeTabID)
        }
        return (TaskManagerRows.snapshot(tabs: infos, bytesByProcess: reading.bytesByProcess), MemoryBudget.footprint(ofProcess: getpid()))
    }

    /// ⌥⌘T — the task manager window.
    @objc func showTaskManager() {
        if taskManager == nil {
            let manager = TaskManagerWindowController()
            manager.provider = { [weak self] in self?.taskManagerSnapshot() ?? (TaskManagerRows.snapshot(tabs: [], bytesByProcess: [:]), nil) }
            manager.onSelect = { [weak self] id in if let tab = self?.tabs.first(where: { $0.id == id }) { self?.selectTab(tab) } }
            manager.onSleep = { [weak self] id in if let tab = self?.tabs.first(where: { $0.id == id }) { self?.sleepTab(tab) } }
            manager.onClose = { [weak self] id in if let tab = self?.tabs.first(where: { $0.id == id }) { self?.closeTab(tab) } }
            taskManager = manager
        }
        taskManager?.show()
    }

    /// JavaScript garbage collection plus WebKit's in-memory caches. At most once a minute:
    /// the collection runs in every web process, so it must not become a constant background cost.
    @discardableResult
    func releaseJavaScriptMemory(reason: String) -> Bool {
        guard Date().timeIntervalSince(lastGarbageCollection) > 60,
              let pool = tabs.compactMap({ $0.webView?.configuration.processPool }).first,
              WebKitTuning.collectJavaScriptGarbage(in: pool) else { return false }
        lastGarbageCollection = Date()
        WebKitTuning.purgeMemoryCaches()
        Log.tabs.notice("Memory cleanup (\(reason, privacy: .public))")
        return true
    }

    /// A tab that has been out of sight for a minute gets its JavaScript memory cleaned, once per absence.
    func cleanHiddenTabsIfDue() async {
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

    func startAudioTimer() {
        audioTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAudioIndicators() }
        }
    }

    func refreshAudioIndicators() {
        for tab in tabs where tab.webView != nil { tab.tabButton.setAudio(tab.audioState) }
    }

    // MARK: - Tab menu, reopen, shortcuts

    func makeTabMenu(for tab: Tab) -> NSMenu {
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
        let following = tabs.filter { $0.spaceIndex == tab.spaceIndex }.drop(while: { $0.id != tab.id }).dropFirst()
        add(SettingsStore.shared.tabLayout == .horizontal ? "Fermer les onglets à droite" : "Fermer les onglets en dessous", enabled: !following.isEmpty) { [weak self] in
            for other in following { self?.closeTab(other) }
        }
        add("Ouvrir dans une mini-fenêtre", enabled: tab.currentURL != nil) { [weak self, weak tab] in if let url = tab?.currentURL { self?.openMiniWindow(url: url) } }
        add("Déplacer vers une nouvelle fenêtre", enabled: tabs.count > 1) { [weak self, weak tab] in if let tab { self?.detachToNewWindow(tab) } }
        add("Fermer les autres onglets", enabled: tabs.filter({ $0.spaceIndex == tab.spaceIndex }).count > 1) { [weak self] in
            guard let self else { return }
            for other in self.tabs where other.id != tab.id && other.spaceIndex == tab.spaceIndex { self.closeTab(other) }
        }
        add("Fermer l'onglet") { [weak self] in self?.closeTab(tab) }
        return menu
    }

    // MARK: Now playing card

    /// A page's script found the site already dark: remember it, so night mode leaves it alone.
    func nativeDarkDetected(_ host: String) {
        let settings = SettingsStore.shared
        let updated = NightPolicy.adding(host, to: settings.nightNativeHosts)
        guard updated != settings.nightNativeHosts else { return }
        settings.nightNativeHosts = updated
        lastNight = nightSignature()
        refreshNightMode()
    }

    func handleMedia(tab: Tab, json: String) {
        guard !tab.isSuspended, tab.webView != nil else { return }
        let info = MediaInfo.parse(json)
        guard tab.media != info else { return }
        tab.media = info
        refreshNowPlaying()
    }

    /// The tab whose media the card shows: one that plays (the one already shown if it still does), else a paused one worth resuming.
    func mediaTab() -> Tab? {
        let candidates = tabs.filter { tab in
            guard !tab.isSuspended, tab.webView != nil, let info = tab.media else { return false }
            return MediaPolicy.isWorthShowing(info, playing: !info.paused)
        }
        let playing = candidates.filter { $0.media?.paused == false }
        if let current = playing.first(where: { $0.id == mediaTabID }) { return current }
        if let first = playing.first { return first }
        return candidates.first { $0.id == mediaTabID } ?? candidates.first
    }

    func refreshNowPlaying() {
        guard let tab = mediaTab(), var info = tab.media else {
            mediaTabID = nil
            if nowPlaying.isShown { nowPlaying.isShown = false; nowPlaying.setArtwork(nil); shownArtwork = nil; MediaKeys.shared.clear() }
            return
        }
        mediaTabID = tab.id
        let host = tab.badgeHost
        info.pictureInPicture = info.pictureInPicture || tab.pictureInPictureActive
        nowPlaying.update(info, host: host, deviceSymbol: audioRoute.output.symbol, deviceLine: audioRoute.line)
        nowPlaying.onTogglePlay = { [weak self, weak tab] in if let tab { self?.mediaCommand(tab, "toggle") } }
        nowPlaying.onSkip = { [weak self, weak tab] seconds in if let tab { self?.mediaCommand(tab, "skip", seconds) } }
        nowPlaying.onSeek = { [weak self, weak tab] fraction in
            if let tab, let duration = tab.media?.duration, duration > 0 { self?.mediaCommand(tab, "seek", fraction * duration) }
        }
        nowPlaying.onPictureInPicture = { [weak self, weak tab] in if let tab { self?.mediaCommand(tab, "pip") } }
        nowPlaying.onRate = { [weak self, weak tab] in
            if let tab, let rate = tab.media?.rate { self?.mediaCommand(tab, "rate", MediaPolicy.nextRate(after: rate)) }
        }
        nowPlaying.onShowTab = { [weak self, weak tab] in if let tab { self?.selectTab(tab) } }
        nowPlaying.isShown = true
        MediaKeys.shared.update(info, host: host) { [weak self, weak tab] action in
            guard let self, let tab else { return }
            switch action {
            case .play: self.mediaCommand(tab, "play")
            case .pause: self.mediaCommand(tab, "pause")
            case .toggle: self.mediaCommand(tab, "toggle")
            case .skip(let seconds): self.mediaCommand(tab, "skip", seconds)
            case .seek(let position): self.mediaCommand(tab, "seek", position)
            }
        }
        loadArtwork(info.artwork, private: tab.isPrivate)
        audioRoute.watchBattery { [weak self] in self?.nowPlaying.isShown == true }
    }

    func mediaCommand(_ tab: Tab, _ name: String, _ value: Double = 0) {
        guard let web = tab.webView else { return }
        if name == "pip", tab.togglePictureInPicture() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refreshNowPlaying() }
            return
        }
        let call = MediaScript.commandCall(name, value: value)
        Task { @MainActor in _ = await web.safeCall(call.body, arguments: call.arguments, world: MediaScript.world) }
    }

    /// The cover given by the page, fetched once per address. Never for a private tab (the request would leave the private session).
    func loadArtwork(_ address: String?, private isPrivate: Bool) {
        let wanted = (isPrivate ? nil : address).flatMap { URL(string: $0)?.scheme == "https" ? $0 : nil }
        guard wanted != shownArtwork else { return }                  // the card refreshes every second: touch the cover only when it changes
        shownArtwork = wanted
        guard let wanted, let url = URL(string: wanted) else { nowPlaying.setArtwork(nil); return }
        if let image = artworkCache[wanted] { nowPlaying.setArtwork(image); return }
        nowPlaying.setArtwork(nil)
        guard artworkRequested.insert(wanted).inserted else { return }
        Task { @MainActor [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url), data.count < 3_000_000, let image = NSImage(data: data) else { return }
            self?.artworkCache[wanted] = image
            if self?.shownArtwork == wanted { self?.nowPlaying.setArtwork(image) }
        }
    }

    // MARK: Invisibility recorder (dev): samples what the user could notice, every 8 ms, until stopped

    var invisTimer: Timer?
    var invisSamples: [[String: Any]] = []
    var invisStart = Date()
    var invisTicks = 0

    /// Called by the navigation delegate while recording: a navigation after the swap is a real reload.
    func noteNavigation(_ kind: String, _ webView: WKWebView) {
        guard invisTimer != nil, let tab = tab(for: webView) else { return }
        invisSamples.append(["t": Int(Date().timeIntervalSince(invisStart) * 1000), "tab": tab.id.uuidString.prefix(4).description, "nav": kind])
    }

    /// Every ~100 ms: where the real page is scrolled, its readyState and a hash of what it shows, to see it move after the swap.
    func samplePage(of tab: Tab) {
        guard let web = tab.webView else { return }
        let tag = tab.id.uuidString.prefix(4).description
        let js = "(function(){var h=5381,s=JSON.stringify((function(){var o=[],a=document.body?document.body.querySelectorAll('p,h1,h2,h3,li,img'):[];for(var i=0;i<a.length&&o.length<80;i++){var r=a[i].getBoundingClientRect();if(r.bottom>0&&r.top<innerHeight)o.push([a[i].tagName,Math.round(r.top),Math.round(r.height)])}return o})());for(var i=0;i<s.length;i++)h=((h<<5)+h+s.charCodeAt(i))>>>0;return Math.round(scrollY)+'|'+document.readyState+'|'+h})()"
        Task { @MainActor in
            guard let out = await web.safeEvaluate(js, frame: nil, world: GhostScript.world) as? String, self.invisTimer != nil else { return }
            self.invisSamples.append(["t": Int(Date().timeIntervalSince(self.invisStart) * 1000), "tab": tag, "page": out])
        }
    }

    func startInvisibilityRecording() {
        invisTimer?.invalidate()
        invisSamples = []; invisStart = Date(); invisTicks = 0
        invisTimer = Timer.scheduledTimer(withTimeInterval: 0.008, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let tab = self.activeTab else { return }
                self.invisTicks += 1
                if self.invisTicks % 12 == 0 { self.samplePage(of: tab) }
                if self.invisSamples.count > 60_000 { self.invisTimer?.invalidate(); self.invisTimer = nil; return }   // forgotten recorder: ~8 min
                self.invisSamples.append([
                    "t": Int(Date().timeIntervalSince(self.invisStart) * 1000), "tab": tab.id.uuidString.prefix(4).description,
                    "stack": tab.probeStack, "bar": Double(self.loadingBar.visibleOpacity), "spin": tab.tabButton.isLoading,
                    "stop": self.reloadButton.symbol == "xmark",
                ])
            }
        }
    }

    /// Writes the samples to /tmp/oree-invis.json and returns how many were taken.
    func stopInvisibilityRecording() -> String {
        invisTimer?.invalidate(); invisTimer = nil
        if let data = try? JSONSerialization.data(withJSONObject: invisSamples) { try? data.write(to: URL(fileURLWithPath: "/tmp/oree-invis.json")) }
        return "samples=\(invisSamples.count)"
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

    func tab(for webView: WKWebView) -> Tab? {
        tabs.first { $0.webView === webView }
    }

    /// The pointer rests on a sleeping tab: wake it in the background so the click finds it ready.
    /// Skipped when the Mac is already over the memory budget.
    func prewake(_ tab: Tab) {
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
    func clearWakeRevealIfNeeded(for tab: Tab) {
        guard tab.isAwaitingWakeReveal else { return }
        tab.finishWakeReveal()
    }

    // MARK: - Session restoration

    /// Benchmarks and tests launch with `HB_FRESH_SESSION=1`: start empty and
    /// never touch the saved session.
    let isFreshSession: Bool
    /// A window opened with ⌘N after the first one: its tabs are not saved nor restored (the saved session is the first window's).
    let isSecondary: Bool
    /// A small floating window for a quick look (a link, a video): no sidebar, always on top, one click to bring the page back to the main window.
    private(set) var isMini = false

    /// Set by the app: the windows opened after the first one, oldest first (the order they come back in).
    public static var extraWindowsProvider: (() -> [BrowserWindowController])?
    /// True while the app brings the saved windows back: a half-restored set must not be saved over the rest.
    public static var suspendExtraSaves = false

    /// Writes the tabs of every extra window (private tabs and blank pages left out); a window with nothing to save is dropped.
    public static func saveExtraWindows() {
        guard !suspendExtraSaves, let controllers = extraWindowsProvider?() else { return }
        let windows: [[ExtraWindowTab]] = controllers.map { controller in
            let savable = controller.tabs.filter { SessionPolicy.isSavable(url: $0.currentURL, isPrivate: $0.isPrivate) }
            return savable.map { tab in
                ExtraWindowTab(url: tab.currentURL?.absoluteString ?? "", interactionState: tab.currentInteractionState, title: tab.displayTitle,
                               spaceIndex: tab.spaceIndex, isActive: tab.id == controller.activeTabID)
            }
        }.filter { !$0.isEmpty }
        do { try ExtraWindowsRepository().save(windows) } catch { Log.storage.error("Failed to save extra windows: \(error.localizedDescription, privacy: .public)") }
    }

    public static func savedExtraWindows() -> [[ExtraWindowTab]] { (try? ExtraWindowsRepository().load()) ?? [] }

    /// Fills this (new, empty) window with the tabs it had: all asleep but the one that was in front.
    public func restoreExtraWindow(_ saved: [ExtraWindowTab]) {
        guard !saved.isEmpty else { return }
        let activeIndex = saved.firstIndex(where: \.isActive) ?? 0
        for (index, item) in saved.enumerated() {
            let config = makeConfiguration(isPrivate: false)
            let space = min(max(item.spaceIndex, 0), spaces.count - 1)
            if index != activeIndex, let url = URL(string: item.url) {
                let sleeper = Tab(configuration: config, isPrivate: false, sleeping: (url, item.interactionState, item.title))
                sleeper.spaceIndex = space
                attachTab(sleeper)
                continue
            }
            let tab = Tab(configuration: config, isPrivate: false)
            tab.spaceIndex = space
            attachTab(tab)
            if let state = item.interactionState { tab.webView?.interactionState = state } else { load(urlString: item.url, in: tab) }
        }
        if tabs.indices.contains(activeIndex) { selectTab(tabs[activeIndex]) } else if let first = tabs.first { selectTab(first) }
    }

    /// Set by the app: opens another window (with a first tab, or empty when a tab is about to be moved in) and returns it.
    /// `BrowserWindowController` cannot do it itself, it does not own the app's services.
    public static var newWindowHandler: ((_ withTab: Bool) -> BrowserWindowController?)?
    @objc func newWindowAction() { _ = Self.newWindowHandler?(true) }

    /// Moves `tab` (page alive: playing video, typed text and scroll are kept) into a new window.
    func detachToNewWindow(_ tab: Tab) {
        guard tabs.count > 1, tabs.contains(where: { $0.id == tab.id }), let other = Self.newWindowHandler?(false) else { NSSound.beep(); return }
        let wasActive = activeTabID == tab.id
        let index = tabs.firstIndex { $0.id == tab.id } ?? 0
        if let pair = splitPair, tab.id == pair.left || tab.id == pair.right { endSplit(keeping: tab.id == pair.left ? pair.right : pair.left) }
        extensionManager.tabClosed(tab)
        tab.contentSlot.removeFromSuperview()
        tab.tabButton.removeFromSuperview()
        tabs.removeAll { $0.id == tab.id }
        rebuildTabList()
        updateTabCount()
        saveSession()
        if wasActive, let next = TabSelection.neighbor(afterRemovingIndex: index, spaces: tabs.map(\.spaceIndex), space: tab.spaceIndex) { selectTab(tabs[next]) }
        else if wasActive, let first = tabs.first { selectTab(first) }
        other.adopt(tab)
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

    // MARK: - Navigation

    func load(urlString raw: String, in tab: Tab) {
        guard let resolution = AddressResolver.resolve(raw, defaultEngine: SettingsStore.shared.searchEngine,
                                                       custom: SettingsStore.shared.customSearchShortcuts) else { return }
        let url = resolution.url
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
    func updateLoadingIndicator(for tab: Tab) {
        guard tab.id == activeTabID else { return }
        downloads.pageLoading(tab.webView?.isLoading == true)       // downloads yield to the page being loaded
        if tab.showsLoading {
            reloadButton.symbol = "xmark"
            reloadButton.onClick = { [weak self] in self?.stopLoadingAction() }
            reloadButton.setAccessibilityLabel("Arrêter le chargement")
        } else {
            reloadButton.symbol = "arrow.clockwise"
            reloadButton.onClick = { [weak self] in self?.reloadAction() }
            reloadButton.setAccessibilityLabel("Recharger la page")
        }
    }

    /// The user agent for the page about to load: WebKit's own (Safari's) unless the user chose another identity, globally or for this site.
    func applyUserAgent(to webView: WKWebView, for url: URL?) {
        let settings = SettingsStore.shared
        let agent = UserAgent.override(mode: settings.userAgentMode, custom: settings.customUserAgent, host: url?.host, chromeHosts: settings.chromeUserAgentHosts,
                                       mobileHosts: settings.mobileSiteHosts)
        if webView.customUserAgent != agent { webView.customUserAgent = agent }
    }

    /// Palette action: ask this site for its mobile version (or the desktop one again), then reload.
    func toggleMobileForCurrentSite() {
        guard let tab = activeTab, let host = tab.webView?.url?.host else { return }
        let settings = SettingsStore.shared
        var hosts = settings.mobileSiteHosts
        if let index = hosts.firstIndex(where: { UserAgent.hostMatches(host, listed: $0) }) { hosts.remove(at: index) } else { hosts.append(host) }
        settings.mobileSiteHosts = hosts
        tab.webView?.reload()
        presentNotice(hosts.contains(where: { UserAgent.hostMatches(host, listed: $0) }) ? "\(host) s’affiche en version mobile." : "\(host) s’affiche en version ordinateur.")
    }

    /// Palette action: present as Chrome on this site (or stop doing so), then reload.
    func toggleChromeAgentForCurrentSite() {
        guard let tab = activeTab, let host = tab.webView?.url?.host else { return }
        let settings = SettingsStore.shared
        var hosts = settings.chromeUserAgentHosts
        if let index = hosts.firstIndex(where: { UserAgent.hostMatches(host, listed: $0) }) { hosts.remove(at: index) } else { hosts.append(host) }
        settings.chromeUserAgentHosts = hosts
        tab.webView?.reload()
        presentNotice(hosts.contains(where: { UserAgent.hostMatches(host, listed: $0) }) ? "\(host) voit Orée comme Chrome." : "\(host) voit Orée comme Safari.")
    }

    /// Shows a popover under `anchor`, or under `fallback` when the anchor is not on screen (a toolbar button the user removed, a window not shown):
    /// AppKit raises an exception for a popover without a place, which used to stop the whole app. Returns false if it could not be shown.
    @discardableResult
    func showPopoverSafely(_ popover: NSPopover, relativeTo anchor: NSView, fallback: NSView? = nil, edge: NSRectEdge = .maxY) -> Bool {
        func usable(_ view: NSView?) -> NSView? {
            guard let view, view.window != nil, !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
            return view
        }
        guard let target = usable(anchor) ?? usable(fallback) else { Log.tabs.error("Popover not shown: no visible place for it"); return false }
        var reason: NSString?
        if OreeShowPopover(popover, target.bounds, target, edge, &reason) { return true }
        Log.tabs.error("Popover refused by AppKit: \((reason as String?) ?? "?", privacy: .public)")
        return false
    }

    /// The notes pad, under the address bar: on the note about this page, or the last one. `append` adds a selection from the page.
    @objc func showNotes() { openNotes(append: nil) }

    func openNotes(append: String?) {
        if let popover = notesPopover, popover.isShown, let view = notesView {
            if let append { view.append(append) } else { popover.close() }
            return
        }
        let url = activeTab?.currentURL.flatMap { $0.scheme == "http" || $0.scheme == "https" ? $0.absoluteString : nil }
        let view = NotesPanelView(repo: noteRepo, pageURL: url, append: append)
        let controller = NSViewController()
        controller.view = view
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        popover.contentSize = NotesPanelView.size
        notesView = view
        notesPopover = popover
        NotificationCenter.default.addObserver(forName: NSPopover.willCloseNotification, object: popover, queue: .main) { [weak view] _ in
            MainActor.assumeIsolated { view?.saveNow() }
        }
        if showPopoverSafely(popover, relativeTo: addressPill, fallback: window?.contentView, edge: .minY) { DispatchQueue.main.async { view.focusText() } }
    }

    /// The QR code of the page's address, to scan with a phone, with copy and save.
    @objc func showPageQRCode() {
        guard let url = activeTab?.webView?.url, url.scheme == "http" || url.scheme == "https",
              let image = PrivacyTools.qrImage(for: url.absoluteString) else { presentNotice("Cette page n’a pas d’adresse à partager."); return }
        if let popover = qrPopover, popover.isShown { popover.close(); return }
        let view = NSImageView(image: image)
        view.frame = NSRect(x: 0, y: 0, width: 220, height: 220)
        let host = url.host ?? url.absoluteString
        let caption = oreeLabel(host, font: Theme.sans(12), color: Theme.muted)
        caption.alignment = .center
        let copy = TextButton("Copier l’image", style: .secondary, height: 28) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
        }
        let stack = NSStackView(views: [view, caption, copy])
        stack.orientation = .vertical; stack.spacing = 10; stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.frame = NSRect(x: 0, y: 0, width: 252, height: 306)
        let controller = NSViewController(); controller.view = stack
        let popover = NSPopover(); popover.behavior = .transient; popover.contentViewController = controller
        guard showPopoverSafely(popover, relativeTo: addressPill) else { return }
        qrPopover = popover
    }

    func dismissNotice() { noticePill.dismiss() }
    func presentStoppableNotice(_ message: String, button: String, perform: @escaping () -> Void) {
        noticePill.show(message: message, button: button, seconds: 3600, perform: perform)
    }

    func presentNotice(_ message: String) { noticePill.show(message: message, button: "OK", seconds: 6) { } }

    @objc func findInPage() {
        findBarContainer?.isHidden = false
        window?.makeFirstResponder(findField)
    }

    @objc func closeFindBar() {
        findBarContainer?.isHidden = true
        activeTab?.webView?.safeRun("window.getSelection().removeAllRanges()", world: .page)
        if let webView = activeTab?.webView {
            window?.makeFirstResponder(webView)
        }
    }

    @objc func findNext() { runFind(backwards: false) }
    @objc func findPrevious() { runFind(backwards: true) }

    func runFind(backwards: Bool) {
        guard let tab = activeTab else { return }
        let term = findField.stringValue
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        guard !term.isEmpty else { return }
        let js = "window.find('\(term)', false, \(backwards), true, false, true, false)"
        tab.webView?.safeRun(js, world: .page)
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

    /// Favoris › Ajouter tous les onglets aux favoris: every open web page of the current space (private tabs excluded), without duplicates.
    @objc func bookmarkAllTabs() {
        var added = 0
        for tab in visibleTabs() where !tab.isPrivate {
            guard let url = tab.currentURL, url.scheme == "http" || url.scheme == "https", (try? bookmarkRepo.contains(url: url.absoluteString)) == false else { continue }
            if (try? bookmarkRepo.add(url: url.absoluteString, title: tab.displayTitle)) != nil { added += 1 }
        }
        menuBuilder?.refreshBookmarksMenu()
        refreshPinnedIcons()
        presentNotice(added == 0 ? "Tous les onglets sont déjà dans les favoris." : "\(added) onglet\(added > 1 ? "s" : "") ajouté\(added > 1 ? "s" : "") aux favoris.")
    }

    /// Favoris › Exporter les favoris…: a standard bookmarks file (HTML) that Chrome, Safari and Firefox can import.
    @objc func exportBookmarks() {
        guard let window else { return }
        let all = (try? bookmarkRepo.all()) ?? []
        let items = all.map { bookmark -> BookmarkExport.Item in
            let space = bookmark.spaceIndex.flatMap { spaces.indices.contains($0) ? spaces[$0].name : nil } ?? "Tous les espaces"
            return BookmarkExport.Item(title: bookmark.title, url: bookmark.url, folder: space, added: bookmark.createdAt)
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "Favoris Orée.html"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try BookmarkExport.html(items).write(to: url, atomically: true, encoding: .utf8)
                self?.presentNotice("\(items.count) favori\(items.count > 1 ? "s" : "") exporté\(items.count > 1 ? "s" : "").")
            } catch { self?.presentNotice("Impossible d’écrire le fichier : \(error.localizedDescription)") }
        }
    }

    @objc func historyItemClicked(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String, let tab = activeTab else { return }
        load(urlString: urlString, in: tab)
    }

    @objc func bookmarkItemClicked(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String, let tab = activeTab else { return }
        load(urlString: urlString, in: tab)
    }

    func syncToolbar(for tab: Tab) {
        let url = tab.webView?.url ?? tab.currentURL
        addressPill.show(url: (url?.scheme == "http" || url?.scheme == "https") ? url : nil)
        backButton.isEnabled = tab.webView?.canGoBack ?? false
        forwardButton.isEnabled = tab.webView?.canGoForward ?? false
        window?.title = tab.displayTitle
        updateLoadingIndicator(for: tab)
        bindTranslator(of: tab)
    }

    // MARK: - Boosts (change a site with one sentence) and calm mode

    func boostConfig() -> BoostScript.Config {
        BoostScript.config(boosts: (try? boostRepo.all()) ?? [], calmAll: SettingsStore.shared.calmModeEverywhere)
    }

    func boostSignature() -> String {
        let boosts = (try? boostRepo.all()) ?? []
        return "\(SettingsStore.shared.calmModeEverywhere)|" + boosts.map { "\($0.host):\($0.enabled):\($0.calm):\($0.rules.count):\($0.updatedAt.timeIntervalSince1970)" }.joined(separator: ",")
    }

    /// Hands the boosts to every tab: future pages through their scripts, the page on screen at once.
    func refreshBoosts() {
        let config = boostConfig()
        lastBoostSignature = boostSignature()
        for tab in tabs {
            tab.setUserScripts(userScripts(for: tab.currentURL))
            if let web = tab.webView { Task { _ = await web.safeEvaluate(BoostScript.source(config), world: BoostScript.world) } }
        }
    }

    /// ⌘K › « Personnaliser ce site… »: asks what to change, has the local model write the rules, checks them against the page, applies them.
    @objc func customizeSiteAction() {
        guard let tab = activeTab, let web = tab.webView, let host = web.url?.host, TranslationPolicy.canTranslate(url: web.url) else { return }
        if let reason = LocalModel.unavailableReason {
            showSimpleAlert("Personnaliser ce site a besoin du modèle local d'Apple Intelligence.", reason)
            return
        }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "par exemple : cache les recommandations et agrandis le texte"
        let alert = NSAlert()
        alert.messageText = "Personnaliser \(host)"
        alert.informativeText = "Décrivez en une phrase ce que vous voulez changer sur ce site. Seul le style est modifié, et seulement ici."
        alert.accessoryView = field
        alert.addButton(withTitle: "Créer")
        alert.addButton(withTitle: "Annuler")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            let request = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !request.isEmpty else { return }
            self?.createBoost(request: request, for: tab)
        }
        DispatchQueue.main.async { field.becomeFirstResponder() }
    }

    func createBoost(request: String, for tab: Tab) {
        guard let web = tab.webView, let host = web.url?.host else { return }
        boostTask?.cancel()
        noticePill.show(message: "Création du boost…", button: "Annuler", seconds: 150) { [weak self] in self?.boostTask?.cancel(); self?.noticePill.dismiss() }
        boostTask = Task { [weak self] in
            guard let self else { return }
            guard let reply = await web.callJSON(BoostScript.survey, world: BoostScript.world, seconds: 15) as? [String: Any],
                  let raw = reply["candidates"] as? [[String: Any]], !raw.isEmpty else {
                if !Task.isCancelled { self.noticePill.dismiss(); self.showSimpleAlert("Personnalisation impossible", "Je n'ai pas pu lire la structure de cette page.") }
                return
            }
            let candidates = raw.compactMap { item -> BoostPrompt.Candidate? in
                guard let selector = item["s"] as? String, let count = (item["n"] as? NSNumber)?.intValue else { return nil }
                return .init(selector: selector, count: count, text: (item["t"] as? String) ?? "")
            }
            do {
                let answer = try await LocalModel.respond(instructions: BoostPrompt.instructions,
                                                          prompt: BoostPrompt.prompt(request: request, host: host, candidates: candidates), seconds: 150)
                guard !Task.isCancelled else { return }
                let proposed = BoostPolicy.rules(fromModel: answer)
                // Dry run on the page: a rule must match something, and not nearly everything.
                let call = BoostScript.countCall(selectors: proposed.rules.map(\.selector))
                let counted = await web.callJSON(call.body, arguments: call.arguments, world: BoostScript.world, seconds: 15) as? [String: Any]
                let counts = (counted?["counts"] as? [NSNumber])?.map(\.intValue) ?? []
                let texts = (counted?["texts"] as? [NSNumber])?.map(\.intValue) ?? []
                let elements = (counted?["elements"] as? NSNumber)?.intValue ?? 1000
                let pageText = (counted?["pageText"] as? NSNumber)?.intValue ?? 0
                let rules = proposed.rules.enumerated().filter { index, rule in
                    index < counts.count && index < texts.count
                        && BoostPolicy.isAcceptable(rule, matches: counts[index], pageElements: elements, matchedText: texts[index], pageText: pageText)
                }.map(\.element)
                guard !rules.isEmpty || proposed.calm else {
                    self.noticePill.dismiss()
                    self.showSimpleAlert("Rien à changer", "Je n'ai trouvé sur cette page aucun élément qui corresponde à « \(request) ». Essayez avec d'autres mots.")
                    return
                }
                let previous = try? self.boostRepo.boost(for: host)
                try? self.boostRepo.save(Boost(host: host, prompt: request, rules: rules, calm: proposed.calm || (previous?.calm ?? false)))
                self.refreshBoosts()
                let what = rules.isEmpty ? "mode calme" : "\(rules.count) règle\(rules.count > 1 ? "s" : "")"
                self.noticePill.show(message: "Boost appliqué à \(host) (\(what))", button: "Annuler", seconds: 15) { [weak self] in
                    guard let self else { return }
                    if let previous { try? self.boostRepo.save(previous) } else { try? self.boostRepo.remove(host: host) }
                    self.refreshBoosts()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.noticePill.dismiss()
                self.showSimpleAlert("Personnalisation impossible", error as? LocalModel.Failure == .timedOut ? "Le modèle a mis trop de temps à répondre." : "Le modèle n'a pas pu écrire de règles.")
            }
        }
    }

    @objc func removeBoostAction() {
        guard let host = activeTab?.webView?.url?.host else { return }
        try? boostRepo.remove(host: host)
        refreshBoosts()
    }

    /// Calm mode on the current site: on if it was off, off if it was on (the boost's own rules stay).
    @objc func toggleCalmForSiteAction() {
        guard let host = activeTab?.webView?.url?.host, TranslationPolicy.canTranslate(url: activeTab?.webView?.url) else { return }
        var boost = (try? boostRepo.boost(for: host)) ?? Boost(host: host)
        boost.calm.toggle()
        if !boost.calm && boost.rules.isEmpty { try? boostRepo.remove(host: host) } else { try? boostRepo.save(boost) }
        refreshBoosts()
    }

    func showSimpleAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        guard let window else { alert.runModal(); return }
        alert.beginSheetModal(for: window)
    }

    // MARK: - L'essentiel

    func updateDigestButton(for tab: Tab) {
        setRelevant(.essentiel, tab.digestCandidate != nil)
        digestButton.isActive = digestPanel.state != "closed"
        setRelevant(.calendar, tab.eventCandidate != nil)
    }

    /// What a page says about itself in its JSON-LD: a recipe or how-to, an event or booking.
    struct StructuredData { var digest: PageDigest?; var event: CalendarEvent? }

    /// Reads the page's JSON-LD. A busy page can answer late (ads, trackers), so it asks again a couple of times; a reply — even one with
    /// nothing in it — is final. nil only when the page never answered.
    func readStructuredData(in web: WKWebView, attempts: Int) async -> StructuredData? {
        for attempt in 0..<attempts {
            if let reply = await web.callJSON(DigestScript.probe, world: DigestScript.world, seconds: 12) as? [String: Any],
               let blocks = reply["jsonld"] as? [String] {
                let data = StructuredData(digest: DigestParser.fromStructuredData(blocks, pageTitle: (reply["title"] as? String) ?? ""),
                                          event: EventParser.fromStructuredData(blocks))
                Log.tabs.notice("Page data: \(blocks.count) block(s), recipe/how-to \(data.digest == nil ? "none" : "found"), event \(data.event == nil ? "none" : "found") (attempt \(attempt + 1))")
                return data
            }
            Log.tabs.notice("Page data: the page did not answer (attempt \(attempt + 1))")
            try? await Task.sleep(for: .seconds(2))
        }
        return nil
    }

    /// After a page has loaded: does it carry its own recipe / how-to or event data? If so the buttons appear; a recipe opens its essentials
    /// at once (default; no model, instant), the rest gets a one-line offer.
    func probeDigest(for tab: Tab) {
        guard TranslationPolicy.canTranslate(url: tab.webView?.url), let web = tab.webView else { return }
        let key = ResumePolicy.key(for: web.url)
        Task {
            let data = await readStructuredData(in: web, attempts: 3)
            guard ResumePolicy.key(for: web.url) == key else { return }       // the tab moved on meanwhile
            tab.digestCandidate = data?.digest
            tab.eventCandidate = data?.event
            if tab.id == activeTabID { updateDigestButton(for: tab) }
            guard tab.id == activeTabID, digestPanel.state == "closed", let key else { return }
            if let candidate = data?.digest, !digestDismissed.contains(key) {
                if SettingsStore.shared.digestAutoRecipes, candidate.kind == .recipe {
                    noticePill.dismiss()                                          // a "resume reading" offer makes no sense over the essentials
                    openDigest(for: tab)                                          // also after a reload or back/forward: the page is the same recipe
                } else if noticePill.visibleMessage == nil, tab.lastNavigationType == .linkActivated || tab.lastNavigationType == .other {
                    noticePill.show(message: candidate.kind == .recipe ? "Recette détectée" : "Tutoriel détecté", button: "Aller à l'essentiel", seconds: 10) { [weak self, weak tab] in
                        if let tab { self?.openDigest(for: tab); self?.updateDigestButton(for: tab) }
                    }
                }
            } else if let event = data?.event, noticePill.visibleMessage == nil, tab.lastNavigationType == .linkActivated || tab.lastNavigationType == .other {
                noticePill.show(message: "Événement détecté", button: "Ajouter au Calendrier", seconds: 12) { [weak self] in self?.confirmAndAdd(event, page: tab.webView?.url) }
            }
        }
    }

    /// Button, palette and menu: show the essentials of the page, or close them.
    @objc func digestAction() {
        guard let tab = activeTab else { return }
        if digestPanel.state != "closed" { digestPanel.close(byUser: true) } else { openDigest(for: tab) }
        updateDigestButton(for: tab)
    }

    /// The page's own data when it has some (instant); else the local model reads the page's text (about half a minute).
    func openDigest(for tab: Tab) {
        guard let web = tab.webView, let key = ResumePolicy.key(for: web.url) else { return }
        digestTask?.cancel()
        digestKey = key
        digestDismissed.remove(key)                       // asked for again: the user wants it
        if let cached = digestCache[key] { digestPanel.show(cached, notice: cached.source == .structured ? nil : "Écrit par le modèle local.") ; return }
        if let page = tab.digestCandidate {
            digestCache[key] = page
            digestPanel.show(page, notice: nil)
            return
        }
        // No data seen at load (the page may have been slow to answer): look again now, before spending half a minute on the model.
        digestPanel.showBusy("Lecture de la page…") { [weak self] in self?.digestTask?.cancel() }
        digestTask = Task { [weak self, weak tab] in
            guard let self, let tab, let web = tab.webView else { return }
            if let page = await self.readStructuredData(in: web, attempts: 2)?.digest, !Task.isCancelled {
                tab.digestCandidate = page
                self.digestCache[key] = page
                self.digestPanel.show(page, notice: nil)
                self.updateDigestButton(for: tab)
                return
            }
            guard !Task.isCancelled else { return }
            self.digestWithModel(tab: tab, key: key)
        }
    }

    /// The local model reads the page's text.
    func digestWithModel(tab: Tab, key: String) {
        if let reason = LocalModel.unavailableReason {
            digestPanel.showMessage("L'essentiel a besoin du modèle local d'Apple Intelligence. " + reason)
            return
        }
        digestPanel.showBusy("Lecture de la page par le modèle local… (environ 30 secondes)") { [weak self] in self?.digestTask?.cancel() }
        digestTask = Task { [weak self, weak tab] in
            guard let self, let web = tab?.webView else { return }
            guard let page = await web.callJSON(DigestScript.text, world: DigestScript.world, seconds: 15) as? [String: Any],
                  let text = page["text"] as? String, text.count > 200 else {
                if !Task.isCancelled { self.digestPanel.showMessage("Cette page ne contient pas assez de texte à résumer.") }
                return
            }
            let title = (page["title"] as? String) ?? ""
            do {
                let answer = try await LocalModel.respond(instructions: DigestPrompt.instructions, prompt: DigestPrompt.prompt(title: title, text: text), seconds: 150)
                guard !Task.isCancelled else { return }
                guard let raw = DigestParser.fromModel(answer, pageTitle: title) else {
                    self.digestPanel.showMessage("Je n'ai trouvé ni recette, ni étapes, ni verdict dans cette page.")
                    return
                }
                let (checked, dropped) = DigestValidator.checked(raw, against: text)
                guard checked.hasContent else { self.digestPanel.showMessage("Le modèle n'a rien produit qui se retrouve dans la page : rien n'est affiché."); return }
                self.digestCache[key] = checked
                if self.digestCache.count > 30 { self.digestCache.removeValue(forKey: self.digestCache.keys.first ?? key) }
                self.digestPanel.show(checked, notice: dropped > 0 ? "\(dropped) élément\(dropped > 1 ? "s" : "") du résumé, introuvable\(dropped > 1 ? "s" : "") dans la page, \(dropped > 1 ? "ont" : "a") été écarté\(dropped > 1 ? "s" : "")." : nil)
            } catch {
                guard !Task.isCancelled else { return }
                self.digestPanel.showMessage(error as? LocalModel.Failure == .timedOut ? "Le modèle a mis trop de temps à répondre." : "Le résumé a échoué.")
            }
        }
    }

    // MARK: - IA locale

    /// Le panneau IA écarte le bord droit de la page de `pushed` points (0 : il la recouvre ou il est fermé).
    /// Dev : la carte de page (ce que lirait l'IA) de l'onglet, avec son poids estimé.
    func pageMapOp(_ op: String, _ tab: Tab) -> String {
        if op == "pagemapget" || op == "actget" { return pageMapResult }
        #if DEBUG
        if op == "groqkey" || op == "cloudkey" {
            // Dev (debug seulement) : range dans le Trousseau la clé écrite dans /tmp/oree-cloud-key.txt (ligne 1 : mistral ou groq ; ligne 2 : la clé), puis efface le fichier.
            let path = "/tmp/oree-cloud-key.txt"
            defer { try? FileManager.default.removeItem(atPath: path) }
            let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            guard lines.count == 2, let provider = AIProvider(rawValue: lines[0]), provider.isCloud else { return "no key file" }
            let keychain = CloudKeychain(provider)
            return keychain.save(lines[1]) ? "saved \(provider.rawValue) (hasKey=\(keychain.hasKey))" : "keychain refused"
        }
        #endif
        pageMapResult = "pending"
        if op == "act" {
            Task { @MainActor in pageMapResult = await actOp(tab) }
            return "started (lire avec actget)"
        }
        Task { @MainActor in pageMapResult = await pageMapReport(tab) }
        return "started (lire avec pagemapget)"
    }

    /// Dev : exécute l'appel d'outil écrit dans /tmp/oree-ai-action.json, `{"name","arguments","profile","approve"}`. Sans `approve`, toute confirmation est refusée.
    func actOp(_ tab: Tab) async -> String {
        guard let web = tab.webView, let data = FileManager.default.contents(atPath: "/tmp/oree-ai-action.json"),
              let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = spec["name"] as? String else { return "no action file" }
        let argsData = (try? JSONSerialization.data(withJSONObject: spec["arguments"] ?? [:])) ?? Data()
        let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
        let action: AIAction
        do { action = try AIAction.parse(name: name, argumentsJSON: argsJSON) } catch { return "parse error: \(error)" }
        let approve = spec["approve"] as? Bool ?? false
        var asked = ""
        let result = await ActionExecutor.execute(action, in: web, profile: spec["profile"] as? [String: String] ?? [:]) { request in
            asked = request.title + " · " + request.rows.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") + " · " + request.warning
            return approve
        }
        return "ok=\(result.ok) asked=\(result.askedConfirmation) msg=\(result.message)" + (asked.isEmpty ? "" : " question=\(asked)")
    }

    func pageMapReport(_ tab: Tab) async -> String {
        guard let web = tab.webView else { return "no web view" }
        let started = Date()
        guard let map = await PageMapScript.capture(web) else { return "pagemap failed" }
        let text = map.render()
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        return "tokens≈\(PageMap.estimatedTokens(text)) ms=\(ms)\n" + text
    }

    // MARK: - Disposition des boutons (barre d'outils, barre latérale)

    func chromeButton(_ item: ChromeItem) -> ChromeIconButton? {
        switch item {
        case .sidebarToggle: toggleSidebarButton
        case .back: backButton
        case .forward: forwardButton
        case .reload: reloadButton
        case .assistant: assistantButton
        case .calendar: calendarButton
        case .essentiel: digestButton
        case .night: nightButton
        case .translate: translateButton
        case .split: splitButton
        case .customize: customizeButton
        case .downloads: downloadsButton
        case .more: moreButton
        case .favorites: panelButtons.first { $0.kind == .favorites }?.button
        case .history: panelButtons.first { $0.kind == .history }?.button
        case .downloadsPanel: panelButtons.first { $0.kind == .downloads }?.button
        case .reading: panelButtons.first { $0.kind == .reading }?.button
        }
    }

    /// Un bouton « selon la page » sert (ou ne sert plus) : on ne retouche la disposition que si cela change quelque chose.
    func setRelevant(_ item: ChromeItem, _ on: Bool) {
        guard chromeRelevant.contains(item) != on else { return }
        if on { chromeRelevant.insert(item) } else { chromeRelevant.remove(item) }
        applyChromeLayout()
    }

    /// Range chaque bouton là où la disposition le veut : barre d'outils à gauche / à droite, bas de la barre latérale, ou nulle part.
    /// Un bouton « selon la page » reste à sa place (grisé) s'il est épinglé, sinon il n'apparaît que quand il sert.
    func applyChromeLayout() {
        guard let toolbar else { return }
        let layout = SettingsStore.shared.chromeLayout
        appliedChromeLayout = layout
        let stacks: [(ChromeZone, NSStackView?, [NSView])] = [(.toolbarLeading, toolbar.leftStack, []), (.toolbarTrailing, toolbar.rightStack, []), (.sidebarFooter, footerStack, footerTail)]
        for (_, stack, _) in stacks { stack?.arrangedSubviews.forEach { stack?.removeArrangedSubview($0); $0.removeFromSuperview() } }
        let side = CGFloat(layout.iconSize.button), glyph = CGFloat(layout.iconSize.glyph)
        for item in ChromeItem.allCases { chromeButton(item)?.resize(side: side, glyph: glyph) }
        for (zone, stack, tail) in stacks {
            guard let stack else { continue }
            for item in layout.visibleItems(in: zone, relevant: { chromeRelevant.contains($0) }) {
                guard let button = chromeButton(item) else { continue }
                if isMini && zone != .sidebarFooter && ![.sidebarToggle, .back, .forward, .reload].contains(item) { continue }   // a small window keeps the essentials
                button.isHidden = false
                button.isEnabled = !item.isContextual || chromeRelevant.contains(item)
                stack.addArrangedSubview(button)
            }
            tail.forEach(stack.addArrangedSubview)
        }
        for item in ChromeItem.allCases { chromeButton(item)?.contextMenuProvider = { [weak self] in self?.chromeMenu(for: item) } }
        searchRow?.collapsed = !layout.showSearchRow
        newTabRow?.collapsed = !layout.showNewTabRow
    }

    /// Clic droit sur un bouton : le masquer, le déplacer, le garder à sa place — sans passer par les réglages.
    func chromeMenu(for item: ChromeItem) -> NSMenu {
        let menu = NSMenu()
        let layout = SettingsStore.shared.chromeLayout
        func update(_ change: @escaping (inout ChromeLayout) -> Void) {
            var edited = SettingsStore.shared.chromeLayout
            change(&edited)
            SettingsStore.shared.chromeLayout = edited
            applyChromeLayout()
        }
        let header = NSMenuItem(title: item.title, action: nil, keyEquivalent: ""); header.isEnabled = false
        menu.addItem(header)
        if item.isContextual {
            let pin = ClosureMenuItem(title: "Toujours à sa place (grisé quand il ne sert pas)") { update { if $0.pinned.contains(item) { $0.pinned.remove(item) } else { $0.pinned.insert(item) } } }
            pin.state = layout.pinned.contains(item) ? .on : .off
            menu.addItem(pin)
        }
        let move = NSMenuItem(title: "Déplacer vers", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for zone in ChromeZone.allCases where zone != .hidden && zone != layout.zone(of: item) {
            submenu.addItem(ClosureMenuItem(title: zone.title) { update { $0.move(item, to: zone) } })
        }
        move.submenu = submenu
        menu.addItem(move)
        if !item.isRequired { menu.addItem(ClosureMenuItem(title: "Masquer ce bouton") { update { $0.move(item, to: .hidden) } }) }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Personnaliser les barres…") { [weak self] in
            self?.openSettings()
            NotificationCenter.default.post(name: Notification.Name("Oree.selectSettingsCategory"), object: "layout")
        })
        return menu
    }

    /// L'IA ouvre une adresse dans l'onglet actif (la personne la voit) et attend la fin du chargement, au plus 15 s.
    func agentNavigate(_ urlString: String) async -> Bool {
        guard let tab = activeTab, let web = tab.webView else { return false }
        load(urlString: urlString, in: tab)
        try? await Task.sleep(for: .milliseconds(400))
        for _ in 0..<60 where web.isLoading && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(250)) }
        return !web.isLoading
    }

    func pushPage(by pushed: CGFloat) {
        guard let edge = pageTrailing else { return }
        // 8 pt de « chrome » entre la page et le panneau (où se trouve la poignée) ; la page arrondit son coin haut-droit à 14 quand elle est poussée.
        contentContainer.maskedCorners = pushed > 0 ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMaxYCorner]
        Motion.animate(Motion.slow) { edge.animator().constant = pushed > 0 ? -(pushed + 8) : 0 }
    }

    func aiBar() -> AIPanelController {
        if let aiBarController { return aiBarController }
        guard let contentView = window?.contentView else { fatalError("fenêtre sans contenu") }
        let hooks = AIPanelController.Hooks(
            activeWebView: { [weak self] in self?.activeTab?.webView },
            pageHost: { [weak self] in self?.contentContainer },
            navigate: { [weak self] urlString in await self?.agentNavigate(urlString) ?? false },
            openTab: { [weak self] url in _ = self?.newTab(urlString: url.absoluteString, isPrivate: false) },
            windowWidth: { [weak self] in self?.window?.contentView?.bounds.width ?? 1200 },
            isPrivate: { [weak self] in self?.activeTab?.isPrivate ?? false },
            onLayout: { [weak self] pushed in self?.pushPage(by: pushed) })
        let created = AIPanelController(contentView: contentView, top: contentContainer.topAnchor, downloads: downloads, hooks: hooks)
        created.onVisibilityChange = { [weak self] open in self?.assistantButton.isActive = open }
        aiBarController = created
        created.tabChanged(id: activeTab?.id, title: activeTab?.displayTitle)
        return created
    }

    /// ⌘J : le panneau IA (Luciole). Le modèle se réveille dès qu'il s'ouvre, pour être prêt quand la question est tapée.
    @objc func askAIAction() { aiBar().toggle() }

    // MARK: - Add to Calendar

    /// ⌘K › « Ajouter au Calendrier » (or the calendar button): the page's own event data when it has some, else the local model looks for a
    /// date in the text. Always asks before anything leaves the app.
    @objc func addToCalendarAction() {
        guard let tab = activeTab, let web = tab.webView, TranslationPolicy.canTranslate(url: web.url) else { return }
        if let event = tab.eventCandidate { confirmAndAdd(event, page: web.url); return }
        if let reason = LocalModel.unavailableReason {
            showSimpleAlert("Ajouter au Calendrier a besoin du modèle local d'Apple Intelligence.", reason + " Sur les pages qui annoncent leur événement dans leurs données, il fonctionne sans.")
            return
        }
        eventTask?.cancel()
        noticePill.show(message: "Recherche d'une date dans la page…", button: "Annuler", seconds: 150) { [weak self] in self?.eventTask?.cancel(); self?.noticePill.dismiss() }
        eventTask = Task { [weak self] in
            guard let self else { return }
            let event = try? await self.findEventWithModel(in: web)
            guard !Task.isCancelled else { return }
            self.noticePill.dismiss()
            if let event { self.confirmAndAdd(event, page: web.url) }
            else { self.showSimpleAlert("Aucun événement trouvé", "Je n'ai pas trouvé de rendez-vous ou d'événement avec une date claire dans cette page.") }
        }
    }

    /// The local model reads the page's text and names its main event; the date is kept only if the page really mentions that day and month.
    func findEventWithModel(in web: WKWebView) async throws -> CalendarEvent? {
        guard let page = await web.callJSON(DigestScript.text, world: DigestScript.world, seconds: 15) as? [String: Any],
              let text = page["text"] as? String, text.count > 40 else { return nil }
        let now = Date()
        let answer = try await LocalModel.respond(instructions: EventPrompt.instructions(now: now), prompt: "Titre de la page : \((page["title"] as? String) ?? "")\n\nTexte de la page :\n\(DigestValidator.budget(text))", seconds: 150)
        guard var event = EventParser.fromModel(answer), EventValidator.isPlausible(event, pageText: text, now: now) else { return nil }
        if event.url == nil { event.url = web.url?.absoluteString }
        return event
    }

    /// Shows what will be added (title, when, where) and, on "Ajouter", opens Calendar with it.
    func confirmAndAdd(_ event: CalendarEvent, page: URL?) {
        var event = event
        if event.url == nil { event.url = page?.absoluteString }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateStyle = .full
        formatter.timeStyle = event.allDay ? .none : .short
        var lines = [formatter.string(from: event.start)]
        if let end = event.end, !event.allDay, Calendar.current.isDate(end, inSameDayAs: event.start) {
            let time = DateFormatter(); time.locale = formatter.locale; time.timeStyle = .short; time.dateStyle = .none
            lines[0] += " – " + time.string(from: end)
        }
        if let location = event.location { lines.append(location) }
        let alert = NSAlert()
        alert.messageText = event.title
        alert.informativeText = lines.joined(separator: "\n") + "\n\nCalendrier s'ouvre avec cet événement : vous choisissez le calendrier et confirmez."
        alert.addButton(withTitle: "Ajouter au Calendrier")
        alert.addButton(withTitle: "Annuler")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.openInCalendar(event) }
        }
    }

    /// Writes the event as a .ics file and opens it with Calendar (which shows its own "add" window; the app never touches the calendars).
    func openInCalendar(_ event: CalendarEvent) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Oree-Events", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("Événement-\(UUID().uuidString.prefix(8)).ics")
        guard (try? ICSBuilder.build(event).write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Calendar.app"), configuration: NSWorkspace.OpenConfiguration())
        Task { try? await Task.sleep(for: .seconds(180)); try? FileManager.default.removeItem(at: file) }
    }

    // MARK: - Resume where you left off

    /// A report from the page: a video position and/or a reading position. Stored per page (never in a private tab).
    func handleResume(tab: Tab, json: String) {
        guard SettingsStore.shared.resumeEnabled, !tab.isPrivate,
              let data = json.data(using: .utf8), let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = ResumePolicy.key(for: (report["u"] as? String).flatMap { URL(string: $0) }) else { return }
        let title = (report["ti"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key
        let isCurrentPage = ResumePolicy.key(for: tab.webView?.url) == key      // a late report about a page already left
        if let video = report["video"] as? [String: Any] {
            if video["done"] as? Bool == true { try? resumeRepo.clearVideo(key: key) }
            else if let t = (video["t"] as? NSNumber)?.doubleValue, let d = (video["d"] as? NSNumber)?.doubleValue,
                    ResumePolicy.isWorthKeeping(videoSeconds: t, duration: d) {
                try? resumeRepo.update(key: key, title: title, video: (t, d))
            }
        }
        if let reading = report["reading"] as? [String: Any],
           let f = (reading["f"] as? NSNumber)?.doubleValue, let screens = (reading["screens"] as? NSNumber)?.doubleValue {
            if isCurrentPage { tab.readFraction = screens >= ResumePolicy.minimumScreens ? f : nil }
            if f > ResumePolicy.readRange.upperBound { try? resumeRepo.clearReading(key: key) }          // read to the end: done
            else if ResumePolicy.isWorthKeeping(readFraction: f, screens: screens) {
                try? resumeRepo.update(key: key, title: title, reading: (f, (reading["a"] as? String).flatMap { $0.isEmpty ? nil : $0 }))
            }
            if isCurrentPage, tab.id == activeTabID { updateReadingBar(for: tab) }
        }
    }

    /// Dev tooling (automation channel): what is stored for the page and what is on offer.
    func resumeReport(for tab: Tab) -> String {
        guard let key = ResumePolicy.key(for: tab.webView?.url) else { return "no key" }
        var parts = ["key=\(key)"]
        if let point = try? resumeRepo.point(for: key) {
            parts.append("video=\(point.videoSeconds.map { String($0) } ?? "-")")
            parts.append("read=\(point.readFraction.map { String($0) } ?? "-")")
            parts.append("anchor=\(point.anchor ?? "-")")
        } else {
            parts.append("point=none")
        }
        parts.append("notice=\(noticePill.visibleMessage ?? "(none)")")
        parts.append("bar=\(tab.readFraction.map { String($0) } ?? "-")")
        return parts.joined(separator: " ")
    }

    /// The thin line at the bottom of the page: how far down the user is in a long article.
    func updateReadingBar(for tab: Tab?) {
        guard let tab, let fraction = tab.readFraction, SettingsStore.shared.resumeEnabled else { readingBar.isHidden = true; return }
        readingBar.isHidden = false
        readingBar.fill = Theme.accent
        readingBarWidth?.constant = contentContainer.bounds.width * CGFloat(min(max(fraction, 0), 1))
    }

    /// On a fresh visit to a page the user had left half-way, offers to go back to the video position or to the paragraph.
    func offerResume(for tab: Tab) {
        guard SettingsStore.shared.resumeEnabled, !tab.isPrivate, !tab.isAwaitingWakeReveal,
              tab.lastNavigationType == .linkActivated || tab.lastNavigationType == .other,
              let key = ResumePolicy.key(for: tab.webView?.url), let point = try? resumeRepo.point(for: key),
              let offer = ResumePolicy.offer(for: point) else { return }
        let message: String, call: (body: String, arguments: [String: Any])
        switch offer {
        case .video(let seconds):
            message = "Reprendre la vidéo à \(ResumePolicy.clock(seconds)) ?"
            call = ResumeScript.goCall(seconds: seconds, fraction: nil, anchor: nil)
        case .reading(let percent):
            message = "Reprendre la lecture (\(percent) %) ?"
            call = ResumeScript.goCall(seconds: nil, fraction: point.readFraction, anchor: point.anchor)
        }
        noticePill.show(message: message, button: "Reprendre", seconds: 12) { [weak tab] in
            guard let web = tab?.webView else { return }
            Task { _ = await web.safeCall(call.body, arguments: call.arguments, world: ResumeScript.world) }
        }
    }

    // MARK: - Night mode

    var appearanceIsDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    func nightConfig() -> NightScript.Config {
        let settings = SettingsStore.shared
        return .init(enabled: NightPolicy.isActive(mode: settings.nightMode, appearanceIsDark: appearanceIsDark),
                     excluded: settings.nightExcludedHosts, native: settings.nightNativeHosts)
    }

    /// Everything that should make the pages re-read the night settings.
    func nightSignature() -> [String] {
        let settings = SettingsStore.shared
        return [settings.nightMode.rawValue, appearanceIsDark ? "dark" : "light"] + settings.nightExcludedHosts + ["|"] + settings.nightNativeHosts
    }

    /// Hands the current night settings to every tab: future pages through their scripts, the page on screen at once.
    func refreshNightMode() {
        let config = nightConfig()
        for tab in tabs {
            tab.setUserScripts(userScripts(for: tab.currentURL))
            if let web = tab.webView {
                Task { _ = await web.safeEvaluate(NightScript.source(config), world: NightScript.world) }
            }
        }
        if let tab = activeTab { updateNightButton(for: tab) }
    }

    /// The moon next to the address: visible while night mode is on; pressed = this site is being darkened.
    func updateNightButton(for tab: Tab) {
        let settings = SettingsStore.shared
        let host = tab.webView?.url?.host ?? tab.currentURL?.host
        setRelevant(.night, settings.nightMode != .off && TranslationPolicy.canTranslate(url: tab.webView?.url ?? tab.currentURL))
        let active = NightPolicy.isActive(mode: settings.nightMode, appearanceIsDark: appearanceIsDark)
        let excluded = NightPolicy.contains(host, in: settings.nightExcludedHosts)
        nightButton.isActive = active && !excluded
        let label = !active ? "Mode nuit en attente (le Mac est en mode clair)" : excluded ? "Assombrir ce site" : "Laisser ce site clair"
        nightButton.setAccessibilityLabel(label)
        nightButton.toolTip = label
    }

    /// One click: leave this site light, or darken it again.
    @objc func toggleNightForCurrentSite() {
        guard let tab = activeTab, let host = tab.webView?.url?.host ?? tab.currentURL?.host else { return }
        let settings = SettingsStore.shared
        settings.nightExcludedHosts = NightPolicy.contains(host, in: settings.nightExcludedHosts)
            ? NightPolicy.removing(host, from: settings.nightExcludedHosts)
            : NightPolicy.adding(host, to: settings.nightExcludedHosts)
        lastNight = nightSignature()
        refreshNightMode()
    }

    func setNightMode(_ mode: NightMode) {
        SettingsStore.shared.nightMode = mode
        lastNight = nightSignature()
        refreshNightMode()
    }

    // MARK: - Page translation

    /// Keeps the translate button in step with the active tab's translator, and starts recognizing the page language.
    func bindTranslator(of tab: Tab) {
        updateNightButton(for: tab)
        updateReadingBar(for: tab)
        updateDigestButton(for: tab)
        tab.onAddressCopied = { [weak self] address in
            self?.noticePill.show(message: "Adresse copiée", button: "Ouvrir dans Plans") {
                if let url = CopyPolicy.mapsURL(for: address) { NSWorkspace.shared.open(url) }
            }
        }
        guard PageTranslator.isAvailable else { return }
        tab.translator.onChange = { [weak self, weak tab] in
            guard let self, let tab, tab.id == self.activeTabID else { return }
            self.updateTranslateButton(for: tab)
        }
        tab.translator.onFailure = { [weak self] failure in self?.showTranslationFailure(failure) }
        tab.translator.detectIfNeeded()
        updateTranslateButton(for: tab)
    }

    func updateTranslateButton(for tab: Tab) {
        let translator = tab.translator
        setRelevant(.translate, translator.shouldOffer && TranslationPolicy.canTranslate(url: tab.webView?.url))
        translateButton.isActive = translator.state != .idle
        translateButton.ringIndeterminate = translator.isWorking
        let label = translator.state == .idle ? "Traduire la page" : "Afficher la page d'origine"
        translateButton.setAccessibilityLabel(label)
        translateButton.toolTip = label
    }

    /// Translates the active page, or puts the original back when it is already translated.
    @objc func translatePageAction() {
        guard PageTranslator.isAvailable, let tab = activeTab else { return }
        bindTranslator(of: tab)
        tab.translator.toggle()
    }

    /// Asks the system to install the fast translation model for the current page's language (its own download sheet appears).
    @objc func downloadFastTranslationAction() { downloadFastTranslationAction(thenTranslate: false) }

    func downloadFastTranslationAction(thenTranslate: Bool) {
        guard PageTranslator.isAvailable, let window, let tab = activeTab else { return }
        guard let source = tab.translator.pageLanguage, source != "und" else {
            showTranslationFailure(.unknownLanguage)
            return
        }
        TranslationDownload.requestFastModel(source: source, in: window) { [weak tab] error in
            if error == nil, thenTranslate { tab?.translator.translate() }
        }
    }

    func showTranslationFailure(_ failure: PageTranslator.Failure) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        switch failure {
        case .sameLanguage(let name):
            alert.messageText = "Cette page est déjà en \(name)."
        case .unknownLanguage:
            alert.messageText = "Langue de la page non reconnue."
            alert.informativeText = "Il n'y a pas assez de texte pour savoir dans quelle langue elle est écrite."
        case .unsupported(let source, let target):
            alert.messageText = "Traduction impossible"
            alert.informativeText = "Le système ne sait pas traduire de « \(source) » vers « \(target) »."
        case .notInstalled(let source, let target):
            alert.messageText = "Langues à télécharger"
            alert.informativeText = "Pour traduire de « \(source) » vers « \(target) », le système doit d'abord télécharger ces langues."
            alert.addButton(withTitle: "Télécharger")
            alert.addButton(withTitle: "Annuler")
        case .failed(let message):
            alert.messageText = "La traduction a échoué"
            alert.informativeText = message
        }
        guard let window else { return }
        alert.beginSheetModal(for: window) { response in
            if case .notInstalled = failure, response == .alertFirstButtonReturn { self.downloadFastTranslationAction(thenTranslate: true) }
        }
    }

    func recentHistoryForMenu(limit: Int = 15) -> [HistoryEntry] {
        (try? historyRepo.recent(limit: limit)) ?? []
    }

    func allBookmarksForMenu() -> [Bookmark] {
        (try? bookmarkRepo.all()) ?? []
    }

    // MARK: - Tab suspension (memory optimization)

    func startSuspensionTimer() {
        suspensionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.suspendInactiveTabs() }
        }
    }

    /// Steady-state hygiene, once a minute: same pass as the memory timer (freeze / sleep by idle time).
    func suspendInactiveTabs() async {
        await enforceMemoryBudget()
        archiveStaleTabs()
    }

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

    // MARK: - WKNavigationDelegate

    /// Main-frame gatekeeper: URL cleaning, HTTPS-only upgrade, Safe Browsing,
    /// then per-page scripts. Sub-frames and non-web schemes pass straight through.
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.targetFrame?.isMainFrame == true {
            tab(for: webView)?.lastNavigationType = navigationAction.navigationType
            applyUserAgent(to: webView, for: navigationAction.request.url)
            let mobile = SettingsStore.shared.mobileSiteHosts.contains { UserAgent.hostMatches(navigationAction.request.url?.host, listed: $0) }
            preferences.preferredContentMode = mobile ? .mobile : .recommended
        }
        let policy = await decideNavigation(webView, navigationAction, preferences)
        return (policy, preferences)
    }

    func decideNavigation(_ webView: WKWebView, _ navigationAction: WKNavigationAction, _ preferences: WKWebpagePreferences) async -> WKNavigationActionPolicy {
        if let url = navigationAction.request.url, url.scheme == StartPage.actionScheme {
            handleHomeAction(url)
            return .cancel
        }
        if navigationAction.shouldPerformDownload { return .download }
        // A link for another app (mail, phone, a video-call app…): the web view cannot show it, so the system opens it.
        let linkType = navigationAction.navigationType
        let clicked = linkType == .linkActivated || linkType == .formSubmitted
        switch ExternalLinkPolicy.decision(for: navigationAction.request.url, userInitiated: clicked) {
        case .notExternal: break
        case .openDirectly: openExternalLink(navigationAction.request.url, from: webView, ask: false); return .cancel
        case .askFirst: openExternalLink(navigationAction.request.url, from: webView, ask: true); return .cancel
        case .block: presentNotice("Orée n’ouvre pas ce type de lien depuis une page web."); return .cancel
        }
        // ⌥-click on a link: a look at it without leaving the page.
        if linkType == .linkActivated, navigationAction.modifierFlags.contains(.option), let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let tab = tab(for: webView) {
            peek(url, from: tab)
            return .cancel
        }
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
        tab.applyContentRuleLists(ruleLists(for: original))
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
        noteNavigation("start", webView)
        updateLoadingIndicator(for: tab)
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        noteNavigation("commit", webView)
        applySiteZoom(to: webView)
        tab.interstitial.hide()
        tab.pageDidCommit()
        refreshNowPlaying()        // a new page: whatever the old one played is over
        // A reload keeps the pop-up; another page takes it away.
        if tab.id == activeTabID, digestPanel.state != "closed", ResumePolicy.key(for: webView.url) != digestKey { digestPanel.close() }
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
        offerWebStoreInstall(for: tab)
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
            syncToolbar(for: tab)    // also recognizes the page language for the translate button
            offerResume(for: tab)
            probeDigest(for: tab)
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

    // MARK: Installing extensions without the manual steps

    /// A .crx finished downloading (from the Web Store or anywhere): offer to install it right away, in a clear prompt.
    private func offerExtensionInstall(fromFile file: URL) {
        guard file.pathExtension.lowercased() == "crx" else { return }
        noticePill.show(message: "Installer cette extension dans Orée ?", button: "Installer", seconds: 30) { [weak self] in
            self?.installExtension(from: file)
        }
    }

    /// On a Chrome Web Store page the "Add to Chrome" button does nothing in Orée: offer the same thing natively.
    private func offerWebStoreInstall(for tab: Tab) {
        guard tab.id == activeTabID, !tab.isPrivate, let id = WebStoreExtension.id(from: tab.webView?.url),
              Date().timeIntervalSince(webStoreOffered[id] ?? .distantPast) > 60,      // not again at each navigation event of the same page
              let package = WebStoreExtension.packageURL(id: id) else { return }
        webStoreOffered[id] = Date()
        let name = WebStoreExtension.name(fromTitle: tab.webView?.title)
        noticePill.show(message: "Ajouter « \(name) » à Orée ?", button: "Ajouter", seconds: 20) { [weak self] in
            self?.noticePill.show(message: "Téléchargement de « \(name) »…", button: "Masquer", seconds: 60) { }
            Task { @MainActor [weak self] in
                do {
                    let (temporary, response) = try await URLSession.shared.download(from: package)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).crx")
                    try? FileManager.default.removeItem(at: file)
                    try FileManager.default.moveItem(at: temporary, to: file)
                    self?.installExtension(from: file)
                } catch {
                    self?.webStoreOffered[id] = nil
                    self?.noticePill.show(message: "Impossible de télécharger « \(name) ».", button: "OK", seconds: 8) { }
                }
            }
        }
    }

    private func installExtension(from file: URL) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.extensionManager.install(from: file)
                self.noticePill.show(message: "Extension installée.", button: "OK", seconds: 6) { }
            } catch is CancellationError {
                // The user declined in the permission prompt.
            } catch {
                self.noticePill.show(message: "Installation impossible : \(error.localizedDescription)", button: "OK", seconds: 10) { }
            }
        }
    }

    /// Shows an extension's popup next to its toolbar button.
    func presentExtensionPopup(_ action: WKWebExtension.Action, for context: WKWebExtensionContext) {
        guard let popover = action.popupPopover else { return }
        // The button lives in the sidebar: when the sidebar is hidden (compact mode, collapsed, other tab layout) the button has no
        // place on screen and the popover would open in a corner of the window. Fall back on the address bar, then on the page's top.
        func usable(_ view: NSView?) -> NSView? {
            guard let view, view.window != nil, !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
            return view
        }
        let anchor: NSView = usable(extensionButtons[context.uniqueIdentifier]) ?? usable(addressPill) ?? contentContainer
        popover.behavior = .transient
        popover.show(relativeTo: anchor === contentContainer ? NSRect(x: anchor.bounds.midX - 1, y: anchor.bounds.maxY - 2, width: 2, height: 2) : anchor.bounds,
                     of: anchor, preferredEdge: anchor === contentContainer ? .minY : .maxY)
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



