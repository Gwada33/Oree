import AppKit
import WebKit
import BrowserCore

@MainActor
final class Tab: NSObject {
    let id = UUID()
    let tabButton = TabButtonView()
    let isPrivate: Bool
    private let configuration: WKWebViewConfiguration

    /// Stable view added once to the window's content container; hosts
    /// whichever of `webView` / the snapshot / the crash overlay applies.
    /// Keeping this stable (rather than re-parenting the web view itself)
    /// means suspending/waking a tab never touches the outer layout.
    let contentSlot = NSView()

    /// `nil` while the tab is suspended — the whole point of suspension is
    /// to let this (and the WebContent process behind it) actually
    /// deallocate, not just hide it.
    private(set) var webView: WKWebView?
    private let snapshotImageView = NSImageView()
    /// HEIC-compressed snapshot bytes — kept instead of a decoded `NSImage`
    /// so a suspended tab's "last known look" costs tens of KB, not the
    /// megabytes a raw bitmap would, while the tab is sitting there unused.
    private var snapshotData: Data?

    var isSuspended = false {
        // Observation only: lets the sidebar show the "sleeping" look. No behavior depends on it.
        didSet { if oldValue != isSuspended { onSleepChange?(isSuspended) } }
    }
    var onSleepChange: ((Bool) -> Void)?
    private var suspendedURL: URL?
    private var suspendedInteractionState: Data?
    /// Set by `wake()`, cleared once the fresh page finishes loading — tells
    /// the caller when it's safe to drop the snapshot image.
    private(set) var isAwaitingWakeReveal = false

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
        snapshotImageView.imageScaling = .scaleProportionallyUpOrDown
        snapshotImageView.isHidden = true

        super.init()
        Tab.liveCount += 1

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

    // MARK: - Web view lifecycle

    @discardableResult
    private func createWebView() -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
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
        loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] web, _ in
            MainActor.assumeIsolated { self?.onProgress?(web.estimatedProgress, web.isLoading) }
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
        return webView
    }

    /// Whether this tab is actively playing audio/video — such a tab must
    /// never be put to sleep, or the music would just stop.
    func isPlayingMedia() async -> Bool {
        guard let webView else { return false }
        return await webView.requestMediaPlaybackState() == .playing
    }

    /// Fades the page in (called when its first content commits).
    func revealWebView() {
        guard let webView, webView.alphaValue < 1 else { return }
        Motion.animate(Motion.quick) { webView.animator().alphaValue = 1 }
    }

    func setInspectable(_ enabled: Bool) {
        webView?.isInspectable = enabled
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
    }

    /// Fully releases the page: unloads it (which stops any video/audio), cuts every
    /// reference WebKit or we hold to it, and drops the web view so its WebContent
    /// process can exit. Call when the tab is closed for good.
    func tearDown() {
        progressObservation = nil; loadingObservation = nil; titleObservation = nil
        onProgress = nil; onTitleChange = nil
        tabButton.onSelect = nil; tabButton.onClose = nil; tabButton.onReorder = nil; tabButton.contextMenuProvider = nil

        let controller = configuration.userContentController
        controller.removeAllUserScripts()
        controller.removeAllContentRuleLists()
        controller.removeScriptMessageHandler(forName: CredentialScript.handlerName)

        guard let webView else { return }
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        webView.pauseAllMediaPlayback()
        webView.loadHTMLString("", baseURL: nil)   // unloading the document ends playback for certain
        webView.removeFromSuperview()
        self.webView = nil
    }

    /// Captures a compressed snapshot, tears down the live `WKWebView` (and
    /// with it, its WebContent process) to actually free memory, and shows
    /// the snapshot in its place. Caller is responsible for not calling this
    /// on the active tab (there's nothing to show instead).
    func suspend() async {
        guard !isSuspended, let webView, let url = webView.url, url.absoluteString != "about:blank" else { return }

        suspendedInteractionState = webView.interactionState as? Data
        suspendedURL = url
        sleepingTitle = webView.title
        progressObservation = nil
        loadingObservation = nil
        titleObservation = nil

        if let image = try? await webView.takeSnapshot(configuration: nil) {
            // Compressed bytes only — no decoded NSImage is kept in memory
            // while the tab just sits here suspended. Decoded on demand by
            // `wake()`, right when it's actually about to be shown.
            snapshotData = HEICSnapshotCodec.encode(image)
        }

        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil

        isSuspended = true
    }

    /// Rebuilds a fresh `WKWebView` from the saved URL/interaction state.
    /// The caller still needs to set `navigationDelegate`/`uiDelegate` on
    /// the returned view — `Tab` doesn't know about the window controller.
    @discardableResult
    func wake() -> WKWebView {
        guard isSuspended else { return webView ?? createWebView() }

        if let snapshotData {
            snapshotImageView.image = HEICSnapshotCodec.decode(snapshotData)
            snapshotImageView.isHidden = false
        }

        let webView = createWebView()
        if let state = suspendedInteractionState {
            webView.interactionState = state
        } else if let url = suspendedURL {
            webView.load(URLRequest(url: url))
        }
        isAwaitingWakeReveal = true
        isSuspended = false
        return webView
    }

    /// Call once the freshly-woken page has actually loaded something, to
    /// swap the (now stale) snapshot back out and free its memory.
    func finishWakeReveal() {
        guard isAwaitingWakeReveal else { return }
        isAwaitingWakeReveal = false
        snapshotImageView.isHidden = true
        snapshotImageView.image = nil
        snapshotData = nil
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
