import AppKit
import WebKit
import BrowserCore

/// The ghost of a hibernated page: a web view with JavaScript switched off that shows the saved DOM.
/// Scrolling, text selection, `:hover` / `:active`, CSS animations and GIFs all work (they need no JavaScript);
/// every navigation is cancelled and reported instead, so the real page can wake and take over.
@MainActor
final class GhostView: NSObject, WKNavigationDelegate {
    /// Ghosts live in their own process pool so their (script-less) pages never share a process with real tabs.
    private static let pool = ProcessPoolFactory.makeLeanProcessPool()

    let webView: WKWebView
    private let record: GhostRecord
    private var didStart = false
    private var restoreWork: [DispatchWorkItem] = []

    /// A link was clicked or a form submitted inside the ghost (nil = no usable address, e.g. a form).
    var onNavigate: ((URL?) -> Void)?
    /// The ghost has loaded and painted its first content.
    var onReady: (() -> Void)?
    private(set) var loadStarted: Date?
    private(set) var loadTime: TimeInterval?

    init(record: GhostRecord, dataStore: WKWebsiteDataStore, ruleLists: [WKContentRuleList]) {
        self.record = record
        let configuration = WKWebViewConfiguration()
        configuration.processPool = Self.pool
        configuration.websiteDataStore = dataStore      // same store as the tabs: subresources come from the HTTP cache
        ruleLists.forEach { configuration.userContentController.add($0) }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsBackForwardNavigationGestures = false
    }

    func load() {
        loadStarted = Date()
        webView.loadHTMLString(record.html, baseURL: URL(string: record.url))
    }

    func tearDown() {
        restoreWork.forEach { $0.cancel() }
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        preferences.allowsContentJavaScript = false
        // The first main-frame load is our own HTML. Everything else (links, forms, iframes, scripts that cannot
        // run anyway) is cancelled: the real page decides what happens next.
        if !didStart, navigationAction.targetFrame?.isMainFrame == true {
            didStart = true
            return (.allow, preferences)
        }
        // A link to an anchor of the same page (a table of contents): the ghost scrolls there itself, no JavaScript needed.
        if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame == true,
           let target = navigationAction.request.url, target.fragment != nil, Self.sameDocument(target, URL(string: record.url)) {
            return (.allow, preferences)
        }
        if navigationAction.targetFrame?.isMainFrame != false || navigationAction.navigationType == .linkActivated {
            switch navigationAction.navigationType {
            case .linkActivated: onNavigate?(navigationAction.request.url)
            case .formSubmitted, .formResubmitted: onNavigate?(nil)
            default: break
            }
        }
        return (.cancel, preferences)
    }

    /// Same address once the `#fragment` is ignored.
    private static func sameDocument(_ a: URL, _ b: URL?) -> Bool {
        guard let b else { return false }
        func bare(_ url: URL) -> String? {
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            parts.fragment = nil
            return parts.string
        }
        return bare(a) == bare(b)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadTime = loadStarted.map { Date().timeIntervalSince($0) }
        // Scroll first, reveal after: the ghost must never be seen at the top of the page for a frame.
        webView.evaluateJavaScript(GhostScript.restoreScroll(x: record.scrollX, y: record.scrollY), in: nil, in: GhostScript.world) { [weak self] _ in
            MainActor.assumeIsolated { self?.onReady?() }
        }
        // Images and fonts arrive after didFinish and can move things: restore again once the layout has settled.
        let endBoot = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.webView.evaluateJavaScript(GhostScript.endBoot, in: nil, in: GhostScript.world) { _ in } }
        }
        restoreWork.append(endBoot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: endBoot)
        for delay in [0.25, 0.7] {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.restoreScroll() } }
            restoreWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func restoreScroll() {
        webView.evaluateJavaScript(GhostScript.restoreScroll(x: record.scrollX, y: record.scrollY), in: nil, in: GhostScript.world) { _ in }
    }
}

/// Where ghosts are stored: a folder of compressed files in the caches, emptied at every launch and quit
/// (a ghost is a copy of a page you looked at: it must not outlive the session).
enum GhostStorage {
    static let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orée/Ghosts", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        return dir
    }()

    nonisolated(unsafe) static let store: GhostBlobStore? = {
        do { return try GhostBlobStore(directory: directory) }
        catch { Log.storage.error("Ghost store unavailable: \(error.localizedDescription, privacy: .public)"); return nil }
    }()

    static func purge() { try? store?.purge() }
}
