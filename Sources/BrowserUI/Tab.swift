import AppKit
import WebKit
import BrowserCore
import BrowserStorage

@MainActor
final class Tab: NSObject {
    let id = UUID()
    let tabButton = TabButtonView()
    let isPrivate: Bool
    let configuration: WKWebViewConfiguration

    /// Stable view added once to the window's content container; hosts
    /// whichever of `webView` / the snapshot / the crash overlay applies.
    /// Keeping this stable (rather than re-parenting the web view itself)
    /// means suspending/waking a tab never touches the outer layout.
    let contentSlot = ContentSlotView()

    /// `nil` while the tab is suspended — the whole point of suspension is
    /// to let this (and the WebContent process behind it) actually
    /// deallocate, not just hide it.
    private(set) var webView: WKWebView?
    private let snapshotImageView = SnapshotView()
    /// HEIC-compressed snapshot bytes — kept instead of a decoded `NSImage`
    /// so a suspended tab's "last known look" costs tens of KB, not the
    /// megabytes a raw bitmap would, while the tab is sitting there unused.
    private var snapshotData: Data?
    /// Snapshot taken when the user left the tab (so sleeping later costs nothing). Kept on disk.
    private var capturedAt: Date?
    private var snapshotFile: URL {
        Tab.snapshotDirectory.appendingPathComponent("\(id.uuidString).heic")
    }
    static let snapshotDirectory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(ProfileContext.cachesFolderName)/Snapshots", isDirectory: true)
        // Images left by a previous run (quit or crash) are page screenshots nobody needs: remove them.
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Deletes every saved snapshot (called when the app quits).
    static func purgeSnapshots() {
        try? FileManager.default.removeItem(at: snapshotDirectory)
    }

    /// The picture to keep for the next launch: the one of a sleeping tab, or the one taken when the user left the tab.
    var pictureForNextLaunch: Data? {
        if isSuspended { return snapshotData }
        if let capturedAt, capturedAt >= lastActiveDate { return try? Data(contentsOf: snapshotFile) }
        return nil
    }

    private var previewCache: (image: NSImage, at: Date, stamp: Date)?

    /// A picture of this tab's page for the preview card: the live page if there is one, else the picture kept when it went to sleep.
    func previewImage() async -> NSImage? {
        // The same tab again within half a minute: the picture is still good (and a snapshot is not free).
        if let cached = previewCache, Date().timeIntervalSince(cached.at) < 30, cached.stamp == lastActiveDate { return cached.image }
        if let webView, !isAwaitingWakeReveal {
            let configuration = WKSnapshotConfiguration()
            configuration.snapshotWidth = 480
            if let image = try? await webView.takeSnapshot(configuration: configuration) {
                previewCache = (image, Date(), lastActiveDate)
                return image
            }
        }
        if let snapshotData { return HEICSnapshotCodec.decode(snapshotData) }
        if let capturedAt, capturedAt >= lastActiveDate, let data = try? Data(contentsOf: snapshotFile) { return HEICSnapshotCodec.decode(data) }
        return nil
    }

    var isSuspended = false {
        // Observation only: lets the sidebar show the "sleeping" look. No behavior depends on it.
        didSet { if oldValue != isSuspended { onSleepChange?(isSuspended) } }
    }
    var onSleepChange: ((Bool) -> Void)?

    // MARK: Frozen tier
    /// Frozen = the page is alive (instant to resume, nothing reloads) but its JavaScript, timers and
    /// rendering are paused. Asleep (`isSuspended`) = page and process gone, only a snapshot remains.
    private(set) var isFrozen = false {
        didSet { if oldValue != isFrozen { onFreezeChange?(isFrozen) } }
    }
    var onFreezeChange: ((Bool) -> Void)?
    /// True once the user typed into a field / editor of the current page: such a tab may be frozen
    /// but is only torn down when the system really needs the memory.
    var isDirty = false
    private var usedPrivateFreeze = false
    /// The ghost shown while this tab wakes (flag `oree.hibernation.ghost`), and a link clicked in it meanwhile.
    private(set) var ghostView: GhostView?
    private var pendingGhostURL: URL?
    private var ghostShownFrom: Date?
    private var hydration: Task<Void, Never>?
    /// Content-blocking lists for the ghost's own web view (set by the window controller).
    var ghostRuleLists: (() -> [WKContentRuleList])?
    /// A sleep is in progress (it awaits): a second request must not start another.
    private var isSuspending = false
    /// Field values and video position saved just before a forced sleep, put back after the reload.
    private var savedPageState: String?
    private var suspendedURL: URL?
    private var suspendedInteractionState: Data?
    /// Set by `wake()`, cleared once the fresh page finishes loading — tells
    /// the caller when it's safe to drop the snapshot image.
    private(set) var isAwaitingWakeReveal = false
    /// What the interface may show of the load: nothing while a woken tab loads behind its snapshot/ghost, so waking
    /// leaves no trace (no bar at the top, no spinner on the tab, no stop button).
    /// The load that wakes a tab stays silent after the swap too, until it ends or the user goes to another page: modern pages
    /// keep "loading" (trackers, ads) long after they are ready, and a bar appearing then would give the sleep away.
    var showsLoading: Bool { webView?.isLoading == true && !isAwaitingWakeReveal && !silentWakeLoad }
    private var silentWakeLoad = false
    private var wakeURL: URL?
    /// What is stacked on screen right now, for the invisibility recorder (`tab invisstart`): "G" ghost, "S<alpha>" snapshot,
    /// "W<alpha>" real page; "-" when the slot is hidden. A frame with none of them on top is a blank flash.
    var probeStack: String {
        guard !contentSlot.isHidden else { return "-" }
        var parts: [String] = []
        if let g = ghostView?.webView, g.superview != nil, !g.isHidden { parts.append("G") }
        // Presentation layer = what is on screen mid-animation (the model value jumps to the end at once).
        func shown(_ v: NSView) -> Double { Double(v.layer?.presentation()?.opacity ?? Float(v.alphaValue)) }
        if !snapshotImageView.isHidden { parts.append(String(format: "S%.2f", shown(snapshotImageView))) }
        if let w = webView, !w.isHidden { parts.append(String(format: "W%.2f", shown(w))) }
        return parts.joined(separator: "+")
    }
    private func reportProgress() {
        guard let webView else { return }
        if !webView.isLoading { silentWakeLoad = false }
        onProgress?(showsLoading ? webView.estimatedProgress : 0, showsLoading)
    }
    /// The new page committed (its first content is in the view) — the snapshot may only come down after this.
    private var hasCommittedSinceWake = false
    private var wakeStartedAt: Date?

    var lastActiveDate = Date()

    // Journal d'événements (voir BrowserWindowController+Journal.swift) : de quoi mesurer sans rien garder de la page.
    var journalID = SiteHash.randomTabID()
    let journalCreated = Date()
    var journalForegroundSince: Date?
    var journalForegroundTotal: TimeInterval = 0
    var journalLastForeground: Date?
    var journalNavStart: Date?
    var journalNavKind = "other"
    var journalNavSite: String?          // le site de la page affichée, en empreinte (pour les liens du même site et les événements de la page)
    var journalMuted = false             // une page à mot de passe : plus rien n'en est enregistré
    var journalWakeTrigger = "select"
    var journalWakeGhost = false
    /// When this tab's JavaScript memory was last cleaned while hidden.
    var lastCleanup: Date?

    /// The window this tab belongs to (extensions ask "which window is this tab in?").
    weak var owner: BrowserWindowController?

    /// Which space (Perso / Travail / Lecture) this tab lives in.
    var spaceIndex = 0
    /// Constraints pinning `contentSlot` inside the page sheet (the split screen re-pins two of them).
    var slotTop: NSLayoutConstraint?
    var slotLeading: NSLayoutConstraint?
    var slotTrailing: NSLayoutConstraint?
    var slotBottom: NSLayoutConstraint?
    // Mode responsive : la page dans la taille d'un autre appareil.
    var responsive: ResponsiveDevice?
    var slotWidth: NSLayoutConstraint?
    var slotHeight: NSLayoutConstraint?
    var slotCenterX: NSLayoutConstraint?
    /// The tab group this tab sits in (nil = loose page).
    var groupID: UUID?

    /// Process id of the tab's WebContent process (private WebKit property, guarded).
    var webProcessID: Int32? {
        guard let webView, webView.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let pid = (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return pid
    }

    enum AudioState { case none, playing, muted }

    /// What the tab is doing with sound. Uses WebKit's private audio flags, guarded:
    /// if they ever disappear, tabs just never show a speaker.
    var audioState: AudioState {
        guard let webView else { return .none }
        if mediaMutedState & 1 != 0 { return .muted }
        let selector = NSSelectorFromString("_isPlayingAudio")
        guard webView.responds(to: selector) else { return .none }
        return (webView.value(forKey: "_isPlayingAudio") as? Bool) == true ? .playing : .none
    }

    private var mediaMutedState: UInt {
        guard let webView, webView.responds(to: NSSelectorFromString("_mediaMutedState")) else { return 0 }
        return (webView.value(forKey: "_mediaMutedState") as? NSNumber)?.uintValue ?? 0
    }

    /// Mutes or unmutes the page's audio (bit 0 of WebKit's muted-state mask).
    func toggleMute() {
        guard let webView else { return }
        let selector = NSSelectorFromString("_setPageMuted:")
        guard webView.responds(to: selector), let imp = webView.method(for: selector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(imp, to: Function.self)(webView, selector, mediaMutedState & 1 != 0 ? 0 : 1)
    }

    /// Full-page warning/recovery screen (crash, insecure HTTP, unsafe site).
    let interstitial = InterstitialView()
    /// Set by the window: the page's resume script reported a video position or a reading position (JSON).
    /// What this tab is playing, if anything worth a "now playing" card.
    var media: MediaInfo?

    /// Picture in picture through WebKit's own (private, guarded) switch: it needs no user gesture, unlike the page's
    /// `requestPictureInPicture()`, and it is what Safari's own menu calls. Both answer false/nil when this WebKit lacks them.
    var pictureInPictureActive: Bool { (webView?.value(forKey: "_isPictureInPictureActive") as? Bool) == true }
    @discardableResult
    func togglePictureInPicture() -> Bool {
        guard let webView, webView.responds(to: NSSelectorFromString("_togglePictureInPicture")) else { return false }
        let can = (webView.value(forKey: "_canTogglePictureInPicture") as? Bool) == true
        guard can || pictureInPictureActive else { return false }
        webView.perform(NSSelectorFromString("_togglePictureInPicture"))
        return true
    }
    /// The page's own event or booking data, read after load; nil when it has none.
    var eventCandidate: CalendarEvent?
    /// The page's own recipe or how-to data, read after load (instant to show); nil when it has none.
    var digestCandidate: PageDigest?
    /// How far down the user has read this page (0…1), for the progress line; nil on short pages.
    var readFraction: Double?
    /// How the current page was reached (set when the navigation starts): only a fresh visit gets a "resume" offer, not
    /// back/forward or reload, where WebKit already restores the position.
    var lastNavigationType: WKNavigationType = .other {
        // The user reloads, clicks a link or goes back: that load is theirs and shows (only the load that wakes a tab is silent).
        didSet {
            if !isAwaitingWakeReveal, lastNavigationType != .other { silentWakeLoad = false }
            if lastNavigationType != .other { readerOrigin = nil }          // leaving the reader: the page is the real one again
        }
    }
    /// The page this tab shows in reader mode (nil when it shows a page as it is).
    var readerOrigin: URL?
    /// Set by the window: a page's night-mode script found its site already dark (the host is passed).
    /// Set by the window: called when the user copies something that is one postal address.
    var onAddressCopied: ((String) -> Void)?
    func copiedText(_ text: String) {
        if let address = CopyPolicy.postalAddress(in: text) { onAddressCopied?(address) }
    }
    /// Translates this tab's page with the system Translation framework (macOS 26+; inert elsewhere).
    lazy var translator = PageTranslator { [weak self] in self?.webView }

    /// Set when we silently upgraded `http://` to `https://` for this tab, so
    /// a connection failure can offer the user the original HTTP address.
    var upgradedFromHTTP: URL?
    /// How many times each host was auto-upgraded since the last successful
    /// load — guards against a site that redirects https -> http forever.
    var upgradeAttempts: [String: Int] = [:]

    /// The address of the navigation in flight (or that just failed) — so a page
    /// that never loaded still has a name and a URL to retry/restore.
    var lastRequestedURL: URL?
    /// Title remembered for a restored, still-sleeping tab.
    private var sleepingTitle: String?
    /// Load progress (0...1) of the live web view, nil when idle.
    var onProgress: ((Double, Bool) -> Void)?
    /// Fires whenever the page's title changes (navigations, and SPAs retitling themselves).
    var onTitleChange: (() -> Void)?
    private var titleObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?
    private var fullscreenObservation: NSKeyValueObservation?
    /// Fires when the page's address changes without a navigation (single-page apps: YouTube, Gmail…).
    var onURLChange: (() -> Void)?
    private var progressObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?

    /// - Parameter sleeping: restore this tab *without* creating a web view
    ///   (no WebContent process, no page load) until it is first selected.
    ///   Most of a restored session is never looked at, so loading all of it
    ///   at launch wastes both memory and startup time.
    /// Number of `Tab` objects still alive — a closed tab must reach zero references
    /// (the regression this guards: closed tabs kept playing video and kept their RAM).
    nonisolated(unsafe) static var liveCount = 0
    deinit { Tab.liveCount -= 1 }

    init(configuration: WKWebViewConfiguration, isPrivate: Bool, sleeping: (url: URL, interactionState: Data?, title: String?)? = nil) {
        self.configuration = configuration
        self.isPrivate = isPrivate

        contentSlot.translatesAutoresizingMaskIntoConstraints = false

        snapshotImageView.translatesAutoresizingMaskIntoConstraints = false
        snapshotImageView.isHidden = true

        super.init()
        Tab.liveCount += 1
        installPageStateTracking()

        if let sleeping {
            snapshotData = isPrivate ? nil : SnapshotVault.shared.get(for: sleeping.url.absoluteString)   // what it looked like before the last quit
            suspendedURL = sleeping.url
            suspendedInteractionState = sleeping.interactionState
            sleepingTitle = sleeping.title
            isSuspended = true
        } else {
            createWebView()
        }

        contentSlot.addSubview(snapshotImageView)
        NSLayoutConstraint.activate([
            snapshotImageView.topAnchor.constraint(equalTo: contentSlot.topAnchor),
            snapshotImageView.leadingAnchor.constraint(equalTo: contentSlot.leadingAnchor),
            snapshotImageView.trailingAnchor.constraint(equalTo: contentSlot.trailingAnchor),
            snapshotImageView.bottomAnchor.constraint(equalTo: contentSlot.bottomAnchor),
        ])

        contentSlot.addSubview(interstitial)
        NSLayoutConstraint.activate([
            interstitial.topAnchor.constraint(equalTo: contentSlot.topAnchor),
            interstitial.leadingAnchor.constraint(equalTo: contentSlot.leadingAnchor),
            interstitial.trailingAnchor.constraint(equalTo: contentSlot.trailingAnchor),
            interstitial.bottomAnchor.constraint(equalTo: contentSlot.bottomAnchor),
        ])
    }

    // MARK: - Page state tracking

    /// A popup tab is handed the opener's `WKUserContentController` by WebKit, and registering the same
    /// handler name twice there raises an (uncatchable) exception — so install once per controller, and
    /// find the tab from the message's web view instead of capturing one tab in the handler.
    private static let trackedControllers = NSHashTable<WKUserContentController>.weakObjects()
    static let tabsByWebView = NSMapTable<WKWebView, Tab>(keyOptions: .weakMemory, valueOptions: .weakMemory)

    private func installPageStateTracking() {
        let controller = configuration.userContentController
        guard !Tab.trackedControllers.contains(controller) else { return }
        Tab.trackedControllers.add(controller)
        controller.addUserScript(TabPageState.makeUserScript())
        controller.add(TabPageStateHandler(), contentWorld: TabPageState.world, name: TabPageState.handlerName)
        controller.add(TranslationMessageHandler(), contentWorld: TranslationScript.world, name: TranslationScript.handlerName)
        controller.add(CleanCopyMessageHandler(), contentWorld: CleanCopyScript.world, name: CleanCopyScript.handlerName)
        controller.add(NightMessageHandler(), contentWorld: NightScript.world, name: NightScript.handlerName)
        controller.add(ResumeMessageHandler(), contentWorld: ResumeScript.world, name: ResumeScript.handlerName)
        controller.add(MediaMessageHandler(), contentWorld: MediaScript.world, name: MediaScript.handlerName)
        controller.add(JournalMessageHandler(), contentWorld: JournalScript.world, name: JournalScript.handlerName)
        // Ghost hibernation: the page-side capture needs hooks installed before the page's own scripts run, so it is only
        // added to tabs created while the flag is on.
        if SettingsStore.shared.hibernationGhost {
            controller.addUserScript(GhostBootstrap.userScript)
            controller.add(GhostFrameHandler(), contentWorld: .page, name: GhostBootstrap.frameHandler)
        }
    }

    // MARK: Frames that announced themselves (cross-origin iframes can only be captured by asking them)
    private var frameInfos: [WKFrameInfo] = []
    func noteFrame(_ info: WKFrameInfo) {
        guard !info.isMainFrame, frameInfos.count < 40 else { return }
        frameInfos.append(info)
    }
    /// Removes and returns the frame whose address is `src` (the same address twice maps in order).
    private func takeFrame(src: String) -> WKFrameInfo? {
        guard let index = frameInfos.firstIndex(where: { $0.request.url?.absoluteString == src }) else { return nil }
        return frameInfos.remove(at: index)
    }

    /// A new document replaced the old one: its unsaved input is gone with it.
    func pageDidCommit() {
        frameInfos.removeAll()
        translator.reset()
        readFraction = nil
        digestCandidate = nil
        eventCandidate = nil
        isDirty = false
        hasCommittedSinceWake = true
        media = nil
        if silentWakeLoad, webView?.url != wakeURL { silentWakeLoad = false }
        if let origin = readerOrigin, webView?.url != origin { readerOrigin = nil }   // another page was opened: no longer the reader   // the user went elsewhere: a real load
    }

    /// Reads field values and the video position before a forced teardown.
    private func collectPageState() async {
        guard let webView, !webView.isLoading else { savedPageState = nil; return }
        let result = await evaluateWithTimeout(TabPageState.collectCall, world: TabPageState.world, seconds: 2)
        savedPageState = result.flatMap { $0 == "null" ? nil : $0 }
    }

    /// Playing position (seconds) captured with the page state, if a video had been watched for a while.
    private var savedVideoSeconds: Double? {
        guard let data = savedPageState?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object["video"] as? NSNumber)?.doubleValue
    }

    /// In (or entering/leaving) a native fullscreen video: never freeze or sleep such a tab.
    var isInFullscreen: Bool { webView.map { $0.fullscreenState != .notInFullscreen } ?? false }

    /// Runs a script in `world` and returns its string result, or nil on error or after `seconds`. A page that is
    /// stuck never answers: without this deadline one hung tab would block every other tab's sleep.
    func evaluateWithTimeout(_ script: String, in target: WKWebView? = nil, frame: WKFrameInfo? = nil, world: WKContentWorld, seconds: Double) async -> String? {
        guard let webView = target ?? webView else { return nil }
        return await withCheckedContinuation { continuation in
            var finished = false
            let finish: (String?) -> Void = { value in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: value)
            }
            Task { @MainActor in
                let value = await webView.safeEvaluate(script, frame: frame, world: world)
                finish(value as? String)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                finish(nil)
            }
        }
    }

    /// Puts saved field values / video position back into the freshly reloaded page.
    func restorePageStateIfNeeded() {
        guard let json = savedPageState, let webView else { return }
        savedPageState = nil
        webView.safeRun(TabPageState.restoreCall(json: json), world: TabPageState.world)
    }

    // MARK: - Freeze / thaw

    private static let suspendSelector = NSSelectorFromString("_suspendPage:")
    private static let resumeSelector = NSSelectorFromString("_resumePage:")
    private typealias PageSuspendFunction = @convention(c) (AnyObject, Selector, @escaping @convention(block) (Bool) -> Void) -> Void

    private func callPrivate(_ selector: Selector, on webView: WKWebView) -> Bool {
        guard webView.responds(to: selector), let imp = webView.method(for: selector) else { return false }
        unsafeBitCast(imp, to: PageSuspendFunction.self)(webView, selector) { _ in }
        return true
    }

    /// Pauses the page in place. Uses WebKit's private page-suspend when this macOS has it,
    /// otherwise the public media pause (JavaScript keeps running but is throttled while hidden).
    func freeze() {
        guard !isSuspended, !isFrozen, let webView else { return }
        usedPrivateFreeze = callPrivate(Tab.suspendSelector, on: webView)
        if !usedPrivateFreeze { webView.setAllMediaPlaybackSuspended(true) { } }
        isFrozen = true
    }

    /// Resumes a frozen page. Immediate: nothing is reloaded.
    func thaw() {
        guard isFrozen else { return }
        isFrozen = false
        guard let webView else { return }
        if usedPrivateFreeze { _ = callPrivate(Tab.resumeSelector, on: webView) }
        else { webView.setAllMediaPlaybackSuspended(false) { } }
        usedPrivateFreeze = false
        setInspectable(SettingsStore.shared.webInspectorEnabled)
    }

    // MARK: - Web view lifecycle

    @discardableResult
    private func createWebView() -> WKWebView {
        let webView = OreeWebView(frame: .zero, configuration: configuration)
        webView.tab = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true          // pinch to zoom, as in Safari
        webView.isInspectable = SettingsStore.shared.webInspectorEnabled
        // Invisible until the first content commits, so the user sees the dark
        // card instead of WKWebView's white default background flashing.
        webView.alphaValue = 0
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] web, _ in
            MainActor.assumeIsolated { self?.reportProgress() }
        }
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onTitleChange?() }
        }
        // Entering/leaving a fullscreen video: make sure nothing of ours (fade-in, slot animation) leaves the page translucent.
        fullscreenObservation = webView.observe(\.fullscreenState, options: [.new]) { [weak self] web, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A trace for diagnosing a black fullscreen video: where the page lives and whether its window is on screen.
                let window = web.window
                // Entering fullscreen: never let the web view sit at 0 × 0 in WebKit's own window (a black screen).
                if web.fullscreenState != .notInFullscreen, web.frame.isEmpty, let bounds = window?.contentView?.bounds, !bounds.isEmpty {
                    web.frame = bounds
                    web.autoresizingMask = [.width, .height]
                    Log.tabs.notice("Fullscreen: the web view had collapsed to 0 × 0, resized to \(NSStringFromRect(bounds), privacy: .public)")
                }
                Log.tabs.notice("Fullscreen state \(web.fullscreenState.rawValue) frame \(NSStringFromRect(web.frame), privacy: .public) visible \(window?.occlusionState.contains(.visible) ?? false) key \(window?.isKeyWindow ?? false) frozen \(self.isFrozen)")
                web.alphaValue = 1
                self.contentSlot.layer?.removeAllAnimations()
                self.contentSlot.alphaValue = 1
                web.needsDisplay = true
            }
        }
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onURLChange?() }
        }
        loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] web, _ in
            MainActor.assumeIsolated { self?.reportProgress() }
        }
        // Ask WebKit to tell us when real content first paints: that is the right moment to drop the snapshot.
        let renderingSelector = NSSelectorFromString("_setObservedRenderingProgressEvents:")
        if webView.responds(to: renderingSelector), let imp = webView.method(for: renderingSelector) {
            typealias Function = @convention(c) (AnyObject, Selector, UInt) -> Void
            unsafeBitCast(imp, to: Function.self)(webView, renderingSelector, Tab.contentRenderedEvents)
        }
        // Sized by its frame, not by Auto Layout constraints: for a fullscreen video WebKit takes the web view out of this slot and puts it
        // in its own window, which drops every constraint tied to the slot. A web view left with no constraints could collapse to 0 × 0 there
        // (a black fullscreen, seen in the logs), whereas a frame and an autoresizing mask survive the move.
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]
        webView.frame = contentSlot.bounds
        contentSlot.addSubview(webView, positioned: .below, relativeTo: nil)
        self.webView = webView
        Tab.tabsByWebView.setObject(self, forKey: webView)
        return webView
    }

    /// FirstVisuallyNonEmptyLayout | FirstPaintWithSignificantArea (WebKit's `_WKRenderingProgressEvent` bits).
    static let contentRenderedEvents: UInt = (1 << 1) | (1 << 2)

    /// Whether this tab is actively playing audio/video — such a tab must
    /// never be put to sleep, or the music would just stop.
    func isPlayingMedia() async -> Bool {
        guard let webView, !isFrozen else { return false }   // a paused page can't answer
        return await webView.requestMediaPlaybackState() == .playing
    }

    /// Camera, microphone or screen sharing in use — such a tab must keep running.
    var isCapturingMedia: Bool {
        guard let webView else { return false }
        return webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none
    }

    /// Fades the page in (called when its first content commits).
    func revealWebView() {
        // While a ghost covers the tab the real page stays invisible: the hand-over (`hydrate`) shows it, in one frame.
        guard let webView, webView.alphaValue < 1, !(isAwaitingWakeReveal && ghostView != nil) else { return }
        Motion.animate(Motion.quick) { webView.animator().alphaValue = 1 }
    }

    /// WebKit raises an Objective-C exception (uncatchable from Swift → crash) for some page states, so
    /// only touch the property when it really changes, and never on a paused page: that one catches up on thaw.
    func setInspectable(_ enabled: Bool) {
        guard let webView, !isFrozen, webView.isInspectable != enabled else { return }
        webView.isInspectable = enabled
    }

    /// Replaces this tab's content-blocking rule lists, whether or not it
    /// currently has a live web view — a future `wake()` reuses the same
    /// configuration object, so this reaches tabs woken later too.
    func applyContentRuleLists(_ lists: [WKContentRuleList]) {
        let controller = configuration.userContentController
        controller.removeAllContentRuleLists()
        lists.forEach { controller.add($0) }
    }

    /// Replaces the page scripts injected into this tab (fingerprint
    /// protection, per-site cosmetic CSS). `WKUserContentController` can only
    /// remove scripts all at once, so callers pass the complete set.
    func setUserScripts(_ scripts: [WKUserScript]) {
        let controller = configuration.userContentController
        controller.removeAllUserScripts()
        scripts.forEach { controller.addUserScript($0) }
        controller.addUserScript(TabPageState.makeUserScript())
        if SettingsStore.shared.hibernationGhost { controller.addUserScript(GhostBootstrap.userScript) }
    }

    /// Fully releases the page: unloads it (which stops any video/audio), cuts every
    /// reference WebKit or we hold to it, and drops the web view so its WebContent
    /// process can exit. Call when the tab is closed for good.
    func tearDown() {
        progressObservation = nil; loadingObservation = nil; titleObservation = nil; urlObservation = nil; fullscreenObservation = nil
        onProgress = nil; onURLChange = nil; onTitleChange = nil
        tabButton.onSelect = nil; tabButton.onClose = nil; tabButton.onReorder = nil; tabButton.contextMenuProvider = nil

        let controller = configuration.userContentController
        controller.removeAllUserScripts()
        controller.removeAllContentRuleLists()
        controller.removeScriptMessageHandler(forName: CredentialScript.handlerName)
        try? FileManager.default.removeItem(at: snapshotFile)
        dropGhost()

        guard let webView else { return }
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        webView.pauseAllMediaPlayback()
        webView.loadHTMLString("", baseURL: nil)   // unloading the document ends playback for certain
        webView.removeFromSuperview()
        self.webView = nil
    }

    // MARK: - Ghost (docs/oree-hibernation.md)

    /// Freezes the live page into a compressed ghost on disk. False = no ghost (flag off, private tab, page too heavy,
    /// script error…): the caller then relies on the snapshot image alone.
    @discardableResult
    private func captureGhost() async -> Bool {
        guard SettingsStore.shared.hibernationGhost, let webView, GhostPolicy.canCapture(url: webView.url, isPrivate: isPrivate),
              let store = GhostStorage.store else { return false }
        let started = Date()
        guard let record = await buildGhostRecord(), GhostPolicy.accepts(record) else {
            Log.tabs.notice("Ghost: not captured for \(webView.url?.host ?? "?", privacy: .public)")
            return false
        }
        do {
            let packed = try GhostCodec.encode(record)
            try store.put(key: id.uuidString, data: packed)
            Log.tabs.notice("Ghost: \(record.html.utf8.count / 1024) KB -> \(packed.count / 1024) KB in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            return true
        } catch {
            Log.tabs.error("Ghost: storing failed (\(error.localizedDescription, privacy: .public))")
            return false
        }
    }

    /// The live page as a ghost: the page script's capture, then what it could not do itself — snapshots of canvases / videos
    /// it could not read, and the documents of cross-origin frames (each asked to capture itself).
    func buildGhostRecord(timeout: Double = 2) async -> GhostRecord? {
        guard let json = await evaluateWithTimeout(GhostBootstrap.captureCall, world: .page, seconds: timeout),
              let capture = GhostCapture.parse(json) else { return nil }
        var record = capture.record
        if let frames = capture.frames, !frames.isEmpty {
            Log.tabs.notice("Ghost: \(frames.count) iframe(s): \(frames.map { ($0.html == nil ? "cross-origin " : "inline ") + String($0.src.prefix(50)) }.joined(separator: "; "), privacy: .public)")
        }
        record.html = await assemble(capture, originX: 0, originY: 0, depth: 0)
        return record
    }

    /// Fills the placeholders of one capture and returns its main document. Each iframe's document (inline ones, and those of
    /// cross-origin frames that are asked to capture themselves) is embedded in the iframe as a `data:` URL.
    /// (originX, originY) is where this capture's viewport sits in the top-level view.
    private func assemble(_ capture: GhostCapture, originX: Double, originY: Double, depth: Int) async -> String {
        // 1. the document of every iframe of this capture
        var frameDocs: [Int: String] = [:]
        for slot in (capture.frames ?? []).prefix(24) {
            if let html = slot.html {
                frameDocs[slot.n] = html
            } else if depth < 2, !slot.src.isEmpty {
                guard let info = takeFrame(src: slot.src) else {
                    Log.tabs.notice("Ghost: frame \(slot.src.prefix(70), privacy: .public) never announced itself (\(self.frameInfos.count) known)")
                    continue
                }
                guard let json = await evaluateWithTimeout(GhostBootstrap.captureCall, frame: info, world: .page, seconds: 1.5),
                      let sub = GhostCapture.parse(json) else {
                    Log.tabs.notice("Ghost: frame \(slot.src.prefix(70), privacy: .public) did not answer its capture")
                    continue
                }
                frameDocs[slot.n] = await assemble(sub, originX: originX + slot.ox, originY: originY + slot.oy, depth: depth + 1)
            }
        }
        // 2. canvases / videos the page could not read: a snapshot of their rectangle, put in every document of this capture
        var main = capture.html
        for slot in (capture.media ?? []).prefix(12) {
            let rect = CGRect(x: originX + slot.x, y: originY + slot.y, width: slot.w, height: slot.h)
            guard let url = await snapshotDataURL(of: rect) else { continue }
            main = GhostAssembler.insertImage(into: main, slot: slot.n, dataURL: url)
            for (n, html) in frameDocs { frameDocs[n] = GhostAssembler.insertImage(into: html, slot: slot.n, dataURL: url) }
        }
        // 3. embed each frame in the document that holds it. A nested frame always has a higher number than its parent, so going
        // from the highest down puts every frame in its parent before the parent is itself embedded.
        for n in frameDocs.keys.sorted(by: >) {
            guard let document = frameDocs[n] else { continue }
            main = GhostAssembler.insertFrame(into: main, slot: n, document: document)
            for m in frameDocs.keys where m < n { frameDocs[m] = GhostAssembler.insertFrame(into: frameDocs[m] ?? "", slot: n, document: document) }
        }
        return main
    }

    /// A JPEG of one rectangle of the web view (points, view coordinates), as a data URL; nil if empty or too big.
    private func snapshotDataURL(of rect: CGRect) async -> String? {
        guard let webView, rect.width >= 2, rect.height >= 2 else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.snapshotWidth = NSNumber(value: Double(min(rect.width, 1280)))
        guard let image = try? await webView.takeSnapshot(configuration: configuration), let tiff = image.tiffRepresentation,
              let jpeg = NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [.compressionFactor: 0.85]),
              jpeg.count <= 1_500_000 else { return nil }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }

    /// Builds the ghost view from the stored file, or nil (no file, unreadable, flag off) → snapshot fallback.
    private func makeGhostView() -> GhostView? {
        guard SettingsStore.shared.hibernationGhost, let store = GhostStorage.store,
              let data = (try? store.get(key: id.uuidString)) ?? nil,
              let record = try? GhostCodec.decode(data), GhostPolicy.accepts(record) else { return nil }
        let ghost = GhostView(record: record, dataStore: configuration.websiteDataStore, ruleLists: ghostRuleLists?() ?? [])
        ghost.onNavigate = { [weak self] url in self?.pendingGhostURL = url ?? self?.pendingGhostURL }
        return ghost
    }

    // MARK: Hydration: the invisible hand-over from ghost to real page

    private func beginHydration() {
        guard hydration == nil, ghostView != nil else { return }
        hydration = Task { @MainActor [weak self] in await self?.hydrate() }
    }

    /// Waits until the real page (under the ghost) is ready, lines its scroll up with the ghost's, waits for WebKit to have
    /// presented that frame, then swaps ghost → real page in a single animation-free transaction.
    /// Any failure ends in the swap anyway: the real page is what the user came for.
    private func hydrate() async {
        guard let webView, let ghost = ghostView else { return }
        let started = Date()
        // A page that is loaded but never stops changing (carousels, trackers) must not keep the ghost up for ever: that
        // swaps after 2.5 s. A page that is still *loading* is worse than the ghost, so for that case we keep waiting
        // (up to three rounds, ~8 s) and swap only when it is there.
        var readiness: String?
        // Fast path: the moment the real page is complete AND shows what the ghost shows (same text, same places), it is
        // there. Waiting for "nothing moved for 150 ms" instead holds the ghost up to 2.5 s on pages that never stop moving
        // (carousels, clocks, trackers), during which the page looks frozen (no scripts in the ghost).
        let matchDeadline = Date().addingTimeInterval(6)
        var lastMatch = "never complete", scrollFixes = 0, lastScroll: Date?, stablePolls = 0, firstMatch: Date?, previousReal: [GhostItem] = []
        while Date() < matchDeadline {
            guard ghostView === ghost, isAwaitingWakeReveal else { return }
            if ghost.isReady, await evaluateWithTimeout("document.readyState", in: webView, world: GhostScript.world, seconds: 1) == "complete" {
                let g = GhostMatcher.parse(await evaluateWithTimeout(GhostScript.visibleItems, in: ghost.webView, world: GhostScript.world, seconds: 1) ?? "")
                let r = GhostMatcher.parse(await evaluateWithTimeout(GhostScript.visibleItems, in: webView, world: GhostScript.world, seconds: 1) ?? "")
                let similarity = GhostMatcher.similarity(ghost: g, real: r)
                lastMatch = String(format: "text=%.0f%% pos=%.0f%% items=%d/%d g=%@ r=%@", similarity.textMatch * 100, similarity.positionMatch * 100, g.count, r.count, g.prefix(6).map { "\($0.t)@\(Int($0.x)),\(Int($0.y))#\($0.h % 1000)" }.joined(separator: " "), r.prefix(6).map { "\($0.t)@\(Int($0.x)),\(Int($0.y))#\($0.h % 1000)" }.joined(separator: " "))
                // Matching is not enough: a page that is still shifting (late hydration, lazy images) would jump right after the
                // swap. It must also have shown the same thing, at the same places, for two polls in a row (~200 ms).
                stablePolls = r == previousReal ? stablePolls + 1 : 0
                previousReal = r
                let matches = similarity.textMatch >= 0.95 && similarity.positionMatch >= 0.9
                if !matches { firstMatch = nil } else if firstMatch == nil { firstMatch = Date() }
                // A page whose blocks never stop moving (ticker, carousel) is never "stable": after 1.2 s of matching, that is as good as it gets.
                if matches, stablePolls >= 2 || Date().timeIntervalSince(firstMatch ?? Date()) > 1.2 { readiness = "matched"; break }
                // The same text, but somewhere else: the real page did not restore the scroll (or did, partly). Line it up now.
                if scrollFixes < 3, let dy = GhostMatcher.scrollDelta(ghost: g, real: r), abs(dy) >= 1 {
                    scrollFixes += 1
                    _ = await evaluateWithTimeout("window.scrollBy(0, \(dy)); String(window.scrollY)", in: webView, world: GhostScript.world, seconds: 1)
                    lastScroll = Date()
                    continue
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if readiness == nil { Log.tabs.notice("Ghost: no match in 6 s (\(lastMatch, privacy: .public))") }
        for _ in 0..<3 where readiness == nil {
            readiness = await callAsyncWithTimeout(GhostScript.ready, arguments: ["timeoutMs": 2500], seconds: 3.1)
            guard ghostView === ghost, isAwaitingWakeReveal else { return }
            if let r = readiness, r.hasPrefix("timeout"), r.contains("/loading/") { continue }
            break
        }
        guard ghostView === ghost, isAwaitingWakeReveal else { return }          // slept or woke again meanwhile

        var note = "ready=\(readiness ?? "no answer")" + (readiness == "matched" ? "" : " (no match in 6 s: \(lastMatch))")
        // The swap needs a frame the real page has drawn, and a tab that is not on screen draws none (a hover pre-wake
        // wakes tabs in the background). Hold the ghost until the tab is shown (30 s at most), then check the page paints.
        let waitStart = Date()
        while contentSlot.isHidden, Date().timeIntervalSince(waitStart) < 30 {
            try? await Task.sleep(for: .milliseconds(150))
            guard ghostView === ghost, isAwaitingWakeReveal else { return }
        }
        if Date().timeIntervalSince(waitStart) > 0.2 { note += " shownAfter=\(Int(Date().timeIntervalSince(waitStart) * 1000))ms" }
        let painted = await callAsyncWithTimeout(GhostScript.painted, arguments: [:], seconds: 1)
        guard ghostView === ghost, isAwaitingWakeReveal else { return }
        note += " frames=\(painted ?? "no answer")"
        if ghost.isReady {
            let ghostItems = GhostMatcher.parse(await evaluateWithTimeout(GhostScript.visibleItems, in: ghost.webView, world: GhostScript.world, seconds: 1) ?? "")
            let realItems = GhostMatcher.parse(await evaluateWithTimeout(GhostScript.visibleItems, in: webView, world: GhostScript.world, seconds: 1) ?? "")
            let similarity = GhostMatcher.similarity(ghost: ghostItems, real: realItems)
            note += String(format: " text=%.0f%% position=%.0f%%", similarity.textMatch * 100, similarity.positionMatch * 100)
            if let dy = GhostMatcher.scrollDelta(ghost: ghostItems, real: realItems), abs(dy) >= 1 {
                _ = await evaluateWithTimeout("window.scrollBy(0, \(dy)); String(window.scrollY)", in: webView, world: GhostScript.world, seconds: 1)
                lastScroll = Date()
                _ = await callAsyncWithTimeout("await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))); return 'ok'", arguments: [:], seconds: 1)
                note += " scrollFix=\(Int(dy))pt"
            }
            if let state = await evaluateWithTimeout(GhostScript.readUserState, in: ghost.webView, world: GhostScript.world, seconds: 1),
               state != "{\"fields\":[],\"focus\":null,\"selection\":\"\"}" {
                _ = await evaluateWithTimeout(GhostScript.applyUserState(state), in: webView, world: GhostScript.world, seconds: 1)
                note += " userState=carried"
            }
            if let directory = ProcessInfo.processInfo.environment["HB_GHOST_SWAP_DUMP"] { await dumpSwap(ghost: ghost.webView, real: webView, to: directory) }
        } else {
            note += " (ghost not painted yet)"
        }
        guard ghostView === ghost, isAwaitingWakeReveal else { return }
        // A scroll just before the swap leaves the real page without drawn tiles for a moment (the recording of 13 Oct shows ~250 ms of
        // black right after the ghost leaves): give WebKit time to draw them, and wait for a real presentation, not for a timeout.
        if let lastScroll {
            let wait = 0.6 - Date().timeIntervalSince(lastScroll)
            if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
        }
        let presented = await afterNextPresentation(of: webView, timeout: 0.9)
        if !presented { try? await Task.sleep(for: .milliseconds(300)) }
        note += presented ? " presented=yes" : " presented=NO(timeout)"
        guard ghostView === ghost, isAwaitingWakeReveal else { return }
        swapGhostForRealPage()
        Log.tabs.notice("Ghost: swap after \(Int(Date().timeIntervalSince(started) * 1000)) ms of hydration — \(note, privacy: .public)")
    }

    /// Ghost out, real page in, snapshot out: one transaction with every implicit animation disabled.
    private func swapGhostForRealPage() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        webView?.alphaValue = 1
        isAwaitingWakeReveal = false
        reportProgress()
        snapshotImageView.isHidden = true; snapshotImageView.image = nil; snapshotImageView.alphaValue = 1
        snapshotImageView.layer?.backgroundColor = nil
        snapshotData = nil
        let link = pendingGhostURL
        pendingGhostURL = nil
        dropGhost()
        CATransaction.commit()
        if let started = wakeStartedAt {
            Log.tabs.notice("Wake: live page visible after \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            owner?.journalWake(self, ms: Int(Date().timeIntervalSince(started) * 1000))
            wakeStartedAt = nil
        }
        refreshHover()
        // A link clicked in the ghost before the real page was ready: follow it now.
        if let link { webView?.load(URLRequest(url: link)) }
    }

    /// The pointer has not moved but the page under it changed: tell WebKit so `:hover` styles are recomputed.
    private func refreshHover() {
        guard let webView, let window = webView.window else { return }
        let point = window.mouseLocationOutsideOfEventStream
        guard webView.bounds.contains(webView.convert(point, from: nil)),
              let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    /// Resumes once WebKit has presented the web view's next frame (private call, guarded), or after 250 ms.
    /// - Returns: true if WebKit really presented a frame, false if the wait ended on the timeout (or the private call is missing).
    @discardableResult
    private func afterNextPresentation(of view: WKWebView, timeout: Double = 0.25) async -> Bool {
        let selector = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        guard view.responds(to: selector), let imp = view.method(for: selector) else {
            try? await Task.sleep(for: .milliseconds(50)); return false
        }
        typealias Function = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var done = false
            let finish = { (presented: Bool) in if !done { done = true; continuation.resume(returning: presented) } }
            unsafeBitCast(imp, to: Function.self)(view, selector) { DispatchQueue.main.async { finish(true) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// Like `evaluateWithTimeout` but for `callAsyncJavaScript` (a script that awaits), in the ghost world.
    private func callAsyncWithTimeout(_ body: String, arguments: [String: Any], seconds: Double) async -> String? {
        guard let webView else { return nil }
        return await withCheckedContinuation { continuation in
            var finished = false
            let finish: (String?) -> Void = { value in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: value)
            }
            Task { @MainActor in
                let value = await webView.safeCall(body, arguments: arguments, world: GhostScript.world)
                finish(value as? String)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                finish(nil)
            }
        }
    }

    /// Dev only (`HB_GHOST_SWAP_DUMP=/dir`): what the ghost and the real page look like at the very moment of the swap.
    private func dumpSwap(ghost: WKWebView, real: WKWebView, to directory: String) async {
        for (name, view) in [("swap-ghost.png", ghost), ("swap-real.png", real)] {
            guard let image = try? await view.takeSnapshot(configuration: nil), let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }
    }

    private func showGhost(_ ghost: GhostView) {
        ghostView = ghost
        let view = ghost.webView
        view.alphaValue = 0          // invisible until it has painted: the snapshot underneath covers the wait
        contentSlot.addSubview(view, positioned: .below, relativeTo: interstitial)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentSlot.topAnchor), view.leadingAnchor.constraint(equalTo: contentSlot.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentSlot.trailingAnchor), view.bottomAnchor.constraint(equalTo: contentSlot.bottomAnchor),
        ])
        let woke = Date()
        ghost.onReady = { [weak view] in
            view?.alphaValue = 1
            Log.tabs.notice("Ghost: visible \(Int(Date().timeIntervalSince(woke) * 1000)) ms after the wake")
        }
        ghostShownFrom = woke
        ghost.load()
    }

    /// Takes the ghost view off the tab (and stops any hand-over in progress). The stored file stays.
    private func removeGhostView() {
        if let from = ghostShownFrom, ghostView != nil {
            Log.tabs.notice("Ghost: replaced by the real page \(Int(Date().timeIntervalSince(from) * 1000)) ms after the wake")
        }
        ghostShownFrom = nil
        hydration?.cancel(); hydration = nil
        ghostView?.tearDown()
        ghostView = nil
    }

    /// View and stored file: the ghost has done its job (or the tab is closing).
    private func dropGhost() {
        removeGhostView()
        try? GhostStorage.store?.remove(key: id.uuidString)
    }

    /// Takes the snapshot of the page as the user last saw it. Called as the user leaves the tab,
    /// so a later sleep only has to reuse it; stored on disk, not in RAM.
    func captureSnapshot() async {
        // Never for a private tab: its page image must not reach the disk.
        guard !isPrivate, !isSuspended, !isFrozen, let webView, webView.url != nil, !webView.isLoading else { return }
        guard let image = try? await webView.takeSnapshot(configuration: nil),
              let data = HEICSnapshotCodec.encode(image) else { return }
        try? data.write(to: snapshotFile, options: .atomic)
        capturedAt = Date()
    }

    /// Tears down the live `WKWebView` (and with it, its WebContent process) to actually free memory,
    /// and shows the last snapshot in its place. Caller is responsible for not calling this on a tab
    /// that is on screen (there's nothing to show instead). A frozen page is resumed first so its
    /// state can be read. Field values (never passwords) and the video position are saved and put
    /// back when the tab wakes.
    /// - Parameter captureGhost: false under memory pressure (a ghost costs up to ~1 s per tab; the image is enough).
    func suspend(captureGhost: Bool = true) async {
        guard !isSuspended, !isSuspending, let webView, let url = webView.url, url.absoluteString != "about:blank" else { return }
        isSuspending = true
        defer { isSuspending = false }
        dropGhost()      // a ghost view from a wake that never finished must not stay over the new snapshot, nor a stale file survive
        thaw()
        await collectPageState()
        // A translated page would be captured in the translated text, then replaced by the untranslated real page.
        if captureGhost, translator.state == .idle { await self.captureGhost() }

        suspendedInteractionState = webView.interactionState as? Data
        suspendedURL = url
        // YouTube resumes a video from `?t=`: more reliable than seeking after load (an advert plays first).
        if let seconds = savedVideoSeconds, ProtectionPolicy.normalized(url.host) == "youtube.com", url.path == "/watch",
           var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "t" } + [URLQueryItem(name: "t", value: "\(Int(seconds))s")]
            if let resumed = parts.url { suspendedURL = resumed; suspendedInteractionState = nil }
        }
        sleepingTitle = webView.title
        progressObservation = nil
        loadingObservation = nil
        titleObservation = nil
        urlObservation = nil
        fullscreenObservation = nil

        // Reuse the snapshot taken when the user left the tab, unless the page was used since.
        if let capturedAt, capturedAt >= lastActiveDate, let data = try? Data(contentsOf: snapshotFile) {
            snapshotData = data
        } else if let image = try? await webView.takeSnapshot(configuration: nil) {
            snapshotData = HEICSnapshotCodec.encode(image)
        }
        try? FileManager.default.removeItem(at: snapshotFile)
        capturedAt = nil

        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil

        translator.reset()
        isDirty = false
        isSuspended = true
    }

    /// Rebuilds a fresh `WKWebView` from the saved URL/interaction state.
    /// The caller still needs to set `navigationDelegate`/`uiDelegate` on
    /// the returned view — `Tab` doesn't know about the window controller.
    @discardableResult
    func wake() -> WKWebView {
        if isFrozen { thaw() }
        guard isSuspended else { return webView ?? createWebView() }

        if let snapshotData {
            snapshotImageView.image = HEICSnapshotCodec.decode(snapshotData)
            snapshotImageView.alphaValue = 1
            snapshotImageView.isHidden = false
        }

        removeGhostView()      // keep the stored file: it is what we are about to show
        let ghost = makeGhostView()
        journalWakeGhost = ghost != nil
        if ghost != nil {
            // The page under the ghost must be drawn at full opacity: WebKit stops producing frames for a view at alpha 0, so
            // it could not be ready, nor painted, when the swap comes. An opaque layer (the snapshot, or at least the page
            // colour) covers it until then.
            snapshotImageView.layer?.backgroundColor = Theme.cg(Theme.page, in: snapshotImageView)
            snapshotImageView.alphaValue = 1
            snapshotImageView.isHidden = false
        }
        if let ghost { showGhost(ghost) }
        silentWakeLoad = true; wakeURL = suspendedURL
        isAwaitingWakeReveal = true     // before the load starts: its first progress must already be hidden
        let webView = createWebView()
        if ghost != nil { webView.alphaValue = 1 }
        if let state = suspendedInteractionState {
            webView.interactionState = state
        } else if let url = suspendedURL {
            // Cache first: a page seen before comes back from disk without waiting for the network.
            webView.load(URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad))
        }
        wakeStartedAt = Date()
        hasCommittedSinceWake = false
        isSuspended = false
        // Safety net: if WebKit never reports a paint, don't leave the snapshot up forever.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            if self?.hasCommittedSinceWake == true { self?.finishWakeReveal() }
            try? await Task.sleep(for: .seconds(7))
            self?.finishWakeReveal()
        }
        return webView
    }

    /// Call once the freshly-woken page has actually loaded something, to
    /// swap the (now stale) snapshot back out and free its memory.
    func finishWakeReveal() {
        guard isAwaitingWakeReveal else { return }
        // With a ghost on screen, "the real page loaded something" is only the start: hydrate() waits until it is
        // truly ready and swaps in one frame (see below). Calling this again is harmless.
        if ghostView != nil { beginHydration(); return }
        isAwaitingWakeReveal = false
        reportProgress()
        snapshotData = nil
        if let started = wakeStartedAt {
            Log.tabs.notice("Wake: live page visible after \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            owner?.journalWake(self, ms: Int(Date().timeIntervalSince(started) * 1000))
            wakeStartedAt = nil
        }
        // Dissolve instead of cutting, so the swap reads as the page "coming alive", not as a refresh.
        let view = snapshotImageView
        Motion.animate(Motion.quick, { view.animator().alphaValue = 0 }, completion: { [weak self] in
            guard let self, !self.isAwaitingWakeReveal else { return }   // woken again meanwhile: keep the new snapshot
            view.isHidden = true; view.image = nil; view.alphaValue = 1
        })
    }

    // MARK: - Display

    var displayTitle: String {
        let base: String
        if let title = webView?.title, !title.isEmpty {
            base = title
        } else if isSuspended, let sleepingTitle, !sleepingTitle.isEmpty {
            base = sleepingTitle
        } else if let host = (webView?.url ?? lastRequestedURL ?? suspendedURL)?.host {
            base = host
        } else {
            base = "Nouvel onglet"
        }
        return isPrivate ? "\u{1F512} \(base)" : base
    }

    /// Host used for the favicon/letter badge; the app's own pages (oree://) have none.
    var badgeHost: String { currentURL?.scheme == "oree" ? "" : (currentURL?.host ?? "") }

    var currentURL: URL? {
        webView?.url ?? lastRequestedURL ?? suspendedURL
    }

    var currentInteractionState: Data? {
        (webView?.interactionState as? Data) ?? suspendedInteractionState
    }
}

/// Shows a tab's last snapshot behind/over the page while it wakes. A plain layer instead of an
/// `NSImageView`: it has no intrinsic size, so a snapshot taken at another window size (fullscreen!)
/// can never push the window around; it is filled to the view and cropped at the bottom/right edges.
/// The tab's content area. The web view is sized by its frame, not by constraints (see `createWebView`), so this keeps it fitted to the
/// slot on every layout pass, including when WebKit puts it back after a fullscreen video.
final class ContentSlotView: NSView {
    override func layout() {
        super.layout()
        for case let web as WKWebView in subviews where web.frame != bounds { web.frame = bounds }
    }
}

final class SnapshotView: NSView {
    var image: NSImage? { didSet { layer?.contents = image } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .vertical)
        setContentHuggingPriority(.init(1), for: .horizontal)
        setContentHuggingPriority(.init(1), for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }
}
