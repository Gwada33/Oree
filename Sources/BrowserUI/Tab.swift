import AppKit
import WebKit
import BrowserCore

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
    let contentSlot = NSView()

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
            .appendingPathComponent("Orée/Snapshots", isDirectory: true)
        // Images left by a previous run (quit or crash) are page screenshots nobody needs: remove them.
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Deletes every saved snapshot (called when the app quits).
    static func purgeSnapshots() {
        try? FileManager.default.removeItem(at: snapshotDirectory)
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
    /// The new page committed (its first content is in the view) — the snapshot may only come down after this.
    private var hasCommittedSinceWake = false
    private var wakeStartedAt: Date?

    var lastActiveDate = Date()
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
    }

    /// A new document replaced the old one: its unsaved input is gone with it.
    func pageDidCommit() {
        isDirty = false
        hasCommittedSinceWake = true
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
    func evaluateWithTimeout(_ script: String, in target: WKWebView? = nil, world: WKContentWorld, seconds: Double) async -> String? {
        guard let webView = target ?? webView else { return nil }
        return await withCheckedContinuation { continuation in
            var finished = false
            let finish: (String?) -> Void = { value in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: value)
            }
            Task { @MainActor in
                let value = try? await webView.evaluateJavaScript(script, in: nil, contentWorld: world)
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
        webView.evaluateJavaScript(TabPageState.restoreCall(json: json), in: nil, in: TabPageState.world) { _ in }
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
        webView.isInspectable = SettingsStore.shared.webInspectorEnabled
        // Invisible until the first content commits, so the user sees the dark
        // card instead of WKWebView's white default background flashing.
        webView.alphaValue = 0
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] web, _ in
            MainActor.assumeIsolated { self?.onProgress?(web.estimatedProgress, web.isLoading) }
        }
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onTitleChange?() }
        }
        // Entering/leaving a fullscreen video: make sure nothing of ours (fade-in, slot animation) leaves the page translucent.
        fullscreenObservation = webView.observe(\.fullscreenState, options: [.new]) { [weak self] web, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
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
            MainActor.assumeIsolated { self?.onProgress?(web.estimatedProgress, web.isLoading) }
        }
        // Ask WebKit to tell us when real content first paints: that is the right moment to drop the snapshot.
        let renderingSelector = NSSelectorFromString("_setObservedRenderingProgressEvents:")
        if webView.responds(to: renderingSelector), let imp = webView.method(for: renderingSelector) {
            typealias Function = @convention(c) (AnyObject, Selector, UInt) -> Void
            unsafeBitCast(imp, to: Function.self)(webView, renderingSelector, Tab.contentRenderedEvents)
        }
        webView.translatesAutoresizingMaskIntoConstraints = false
        contentSlot.addSubview(webView, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: contentSlot.topAnchor),
            webView.leadingAnchor.constraint(equalTo: contentSlot.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentSlot.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: contentSlot.bottomAnchor),
        ])
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
        guard let json = await evaluateWithTimeout(GhostScript.capture, world: GhostScript.world, seconds: 2),
              let record = GhostRecord.parse(scriptResult: json), GhostPolicy.accepts(record) else {
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
        for _ in 0..<3 {
            readiness = await callAsyncWithTimeout(GhostScript.ready, arguments: ["timeoutMs": 2500], seconds: 3.1)
            guard ghostView === ghost, isAwaitingWakeReveal else { return }
            if let r = readiness, r.hasPrefix("timeout"), r.contains("/loading/") { continue }
            break
        }
        guard ghostView === ghost, isAwaitingWakeReveal else { return }          // slept or woke again meanwhile

        var note = "ready=\(readiness ?? "no answer")"
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
                _ = await callAsyncWithTimeout("await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))); return 'ok'", arguments: [:], seconds: 1)
                note += " scrollFix=\(Int(dy))pt"
            }
            if let directory = ProcessInfo.processInfo.environment["HB_GHOST_SWAP_DUMP"] { await dumpSwap(ghost: ghost.webView, real: webView, to: directory) }
        } else {
            note += " (ghost not painted yet)"
        }
        guard ghostView === ghost, isAwaitingWakeReveal else { return }
        await afterNextPresentation(of: webView)
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
        snapshotImageView.isHidden = true; snapshotImageView.image = nil; snapshotImageView.alphaValue = 1
        snapshotImageView.layer?.backgroundColor = nil
        snapshotData = nil
        let link = pendingGhostURL
        pendingGhostURL = nil
        dropGhost()
        CATransaction.commit()
        if let started = wakeStartedAt {
            Log.tabs.notice("Wake: live page visible after \(Int(Date().timeIntervalSince(started) * 1000)) ms")
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
    private func afterNextPresentation(of view: WKWebView) async {
        let selector = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        guard view.responds(to: selector), let imp = view.method(for: selector) else {
            try? await Task.sleep(for: .milliseconds(50)); return
        }
        typealias Function = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var done = false
            let finish = { if !done { done = true; continuation.resume() } }
            unsafeBitCast(imp, to: Function.self)(view, selector) { DispatchQueue.main.async(execute: finish) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: finish)
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
                let value = try? await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: GhostScript.world)
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
        if captureGhost { await self.captureGhost() }

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
        if ghost != nil {
            // The page under the ghost must be drawn at full opacity: WebKit stops producing frames for a view at alpha 0, so
            // it could not be ready, nor painted, when the swap comes. An opaque layer (the snapshot, or at least the page
            // colour) covers it until then.
            snapshotImageView.layer?.backgroundColor = Theme.cg(Theme.page, in: snapshotImageView)
            snapshotImageView.alphaValue = 1
            snapshotImageView.isHidden = false
        }
        if let ghost { showGhost(ghost) }
        let webView = createWebView()
        if ghost != nil { webView.alphaValue = 1 }
        if let state = suspendedInteractionState {
            webView.interactionState = state
        } else if let url = suspendedURL {
            // Cache first: a page seen before comes back from disk without waiting for the network.
            webView.load(URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad))
        }
        wakeStartedAt = Date()
        isAwaitingWakeReveal = true
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
        snapshotData = nil
        if let started = wakeStartedAt {
            Log.tabs.notice("Wake: live page visible after \(Int(Date().timeIntervalSince(started) * 1000)) ms")
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
