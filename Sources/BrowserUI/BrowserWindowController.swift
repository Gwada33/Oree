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

    // Properties used by the extensions in the BrowserWindowController+*.swift files (extensions cannot hold stored properties).
    /// Reacts to settings that need more than a re-read: the fingerprint
    /// toggle (scripts are baked into each tab) and Safe Browsing on/off/key.
    var lastNight = [] as [String]
    var lastCopySettings = [SettingsStore.shared.cleanCopy, SettingsStore.shared.copyAddsSource, SettingsStore.shared.resumeEnabled]
    var lastShortcutOverrides = SettingsStore.shared.shortcutOverrides
    var lastLook = LookProfile.capture(named: "", from: SettingsStore.shared)
    var lastSidebarPrefs = [SettingsStore.shared.sidebarWidth, SettingsStore.shared.sidebarGlass ? 1 : 0]
    /// Width of the expanded sidebar (user-resizable by dragging its right edge).
    var expandedSidebarWidth: CGFloat { CGFloat(SettingsStore.shared.sidebarWidth) }
    /// Automation only: shows the downloads panel inside the window so a snapshot can capture it (popovers are separate windows).
    var demoPanel: DownloadsPanelView?
    var inlineNewTabRow: SidebarRowView?
    /// Fraction of the budget the last pass found in use; pre-waking is skipped while over budget.
    var isOverBudget = false
    /// One pass of the tab lifecycle, every 20 s (awake → frozen → asleep, see `TabLifecyclePolicy`):
    ///  1. hidden tabs: after a minute out of sight, clean their JavaScript memory (once per absence);
    ///  2. over budget: first clean (cheap, nothing is lost), and only if that isn't enough, apply the plan;
    ///  3. the plan freezes tabs hidden for a while and sleeps the ones hidden very long or, when over
    ///     budget, the best-scoring ones down to 80 % of the budget.
    var isLifecyclePassRunning = false
    var invisTimer: Timer?
    var invisSamples: [[String: Any]] = []
    var invisStart = Date()
    var invisTicks = 0
    /// Benchmarks and tests launch with `HB_FRESH_SESSION=1`: start empty and
    /// never touch the saved session.
    let isFreshSession: Bool
    /// A window opened with ⌘N after the first one: its tabs are not saved nor restored (the saved session is the first window's).
    let isSecondary: Bool
    /// A small floating window for a quick look (a link, a video): no sidebar, always on top, one click to bring the page back to the main window.
    var isMini = false

    public weak var menuBuilder: MenuBuilder?
    var settingsWindow: NSWindow?
    var sessionSaveWork: DispatchWorkItem?
    // Journal d'événements : le contexte du prochain événement (comment l'onglet s'ouvre, comment il est choisi, pourquoi il se ferme), et la saisie en cours dans la barre d'adresse.
    var journalOpenHow = "other"
    var journalSelectVia = "other"
    var journalCloseWhy = "user"
    var journalAddress: (focusedAt: Date, keys: Int, deletes: Int, longest: Int, last: Int, shown: [String: Int], committed: Bool)?
    var journalAIStart: (date: Date, usage: AIUsageMeter.Snapshot, task: String)?
    nonisolated(unsafe) var journalTimer: Timer?
    var journalWasEnabled = false
    var journalDownloadStart: Date?
    var journalLayoutWork: DispatchWorkItem?

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
        view.onUse = { [weak self] section, length, results, ms in
            let action: String
            switch section {
            case "Onglets ouverts": action = "tab"
            case "Espaces": action = "space"
            case "Actions": action = "tool"
            case "Rechercher", "Ouvrir": action = "search"
            default: action = "other"
            }
            self?.journal.emit("palette.use", ["action": .string(action), "q": .int(JournalBucket.log2(length)), "ms": .int(ms), "results": .int(results)])
        }
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
                case "aiusage": return AIUsageMeter.shared.snapshot.summary
                case "aiusagereset": AIUsageMeter.shared.reset(); return "reset"
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
    func userScripts(for url: URL?, isPrivate: Bool = false) -> [WKUserScript] {
        var scripts: [WKUserScript] = [CredentialScript.makeUserScript(), MediaScript.makeUserScript()]
        if SettingsStore.shared.eventJournalEnabled, !isPrivate { scripts.append(JournalScript.makeUserScript()) }      // le journal : jamais dans un onglet privé
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


    func settingsChanged() {
        journalSettingsChanged()
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
            for tab in tabs { tab.setUserScripts(userScripts(for: tab.currentURL, isPrivate: tab.isPrivate)) }
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

    // MARK: - Session restoration


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
    func offerExtensionInstall(fromFile file: URL) {
        guard file.pathExtension.lowercased() == "crx" else { return }
        noticePill.show(message: "Installer cette extension dans Orée ?", button: "Installer", seconds: 30) { [weak self] in
            self?.installExtension(from: file)
        }
    }

    /// On a Chrome Web Store page the "Add to Chrome" button does nothing in Orée: offer the same thing natively.
    func offerWebStoreInstall(for tab: Tab) {
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

    func installExtension(from file: URL) {
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



