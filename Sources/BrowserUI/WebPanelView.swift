import AppKit
import WebKit
import BrowserCore

/// A web app in a card docked to the right of the page (WhatsApp Web, a calendar…). Each app keeps its own page alive while the card is
/// hidden, so a conversation or a timer is still there when it comes back. Logins are shared with the tabs (same data store).
@MainActor
final class WebPanelView: SurfaceView, WKNavigationDelegate, WKUIDelegate {
    static let width: CGFloat = 400
    private let titleLabel = oreeLabel("", font: Theme.sans(13, .semibold), color: Theme.text)
    private let content = NSView()
    private var pages: [String: WKWebView] = [:]
    private var configurationFor: ((WebPanelEntry) -> WKWebViewConfiguration)?
    /// A link that leaves the app (a click on a page of another site): opened in a normal tab.
    var onOpenInTab: ((URL) -> Void)?
    private(set) var current: WebPanelEntry?
    var isShown: Bool { !isHidden }

    init(configuration: @escaping (WebPanelEntry) -> WKWebViewConfiguration) {
        configurationFor = configuration
        super.init(fill: Theme.page, cornerRadius: Theme.radiusLarge + 2)
        border = Theme.line
        elevation = .three
        clips = false
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        let clip = SurfaceView(cornerRadius: Theme.radiusLarge + 2)
        clip.clips = true
        clip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clip)
        let bar = SurfaceView(fill: Theme.chrome)
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(bar); clip.addSubview(content)
        let reload = ChromeIconButton(symbol: "arrow.clockwise", label: "Recharger")
        let open = ChromeIconButton(symbol: "arrow.up.right.square", label: "Ouvrir dans un onglet")
        let close = ChromeIconButton(symbol: "xmark", label: "Fermer le panneau")
        reload.onClick = { [weak self] in self?.currentPage?.reload() }
        open.onClick = { [weak self] in if let url = self?.currentPage?.url { self?.onOpenInTab?(url) } }
        close.onClick = { [weak self] in self?.hide() }
        titleLabel.lineBreakMode = .byTruncatingTail
        let buttons = NSStackView(views: [reload, open, close]); buttons.spacing = 2
        for v in [titleLabel, buttons] { v.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(v) }
        NSLayoutConstraint.activate([
            clip.topAnchor.constraint(equalTo: topAnchor), clip.bottomAnchor.constraint(equalTo: bottomAnchor),
            clip.leadingAnchor.constraint(equalTo: leadingAnchor), clip.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: clip.topAnchor), bar.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: clip.trailingAnchor), bar.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16), titleLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8), buttons.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8),
            content.topAnchor.constraint(equalTo: bar.bottomAnchor), content.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor), content.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var currentPage: WKWebView? { current.flatMap { pages[$0.url] } }

    /// Shows `entry`'s page (loading it the first time), hiding the one that was there.
    func show(_ entry: WebPanelEntry) {
        guard let url = URL(string: entry.url) else { return }
        if let shown = currentPage { shown.isHidden = true }
        let page: WKWebView
        if let existing = pages[entry.url] { page = existing } else {
            page = WKWebView(frame: .zero, configuration: configurationFor?(entry) ?? WKWebViewConfiguration())
            page.translatesAutoresizingMaskIntoConstraints = false
            page.navigationDelegate = self
            page.uiDelegate = self
            content.addSubview(page)
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: content.topAnchor), page.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                page.leadingAnchor.constraint(equalTo: content.leadingAnchor), page.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
            pages[entry.url] = page
            page.load(URLRequest(url: url))
        }
        page.isHidden = false
        current = entry
        titleLabel.stringValue = entry.name
        guard isHidden else { return }
        isHidden = false
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; animator().alphaValue = 1 }
    }

    /// Hides the card; the page stays alive behind it.
    func hide() {
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.14; animator().alphaValue = 0 }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { if let self, self.alphaValue == 0 { self.isHidden = true } }
        })
    }

    /// Takes the app away for good: its page is released.
    func remove(_ entry: WebPanelEntry) {
        if current == entry { hide(); current = nil }
        pages[entry.url]?.stopLoading()
        pages[entry.url]?.removeFromSuperview()
        pages[entry.url] = nil
    }

    // Links to other sites leave the panel for a tab; the app's own pages stay.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame != false,
              let target = navigationAction.request.url, let home = webView.url,
              Self.registrableName(target.host) != Self.registrableName(home.host) else { return .allow }
        onOpenInTab?(target)
        return .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { onOpenInTab?(url) }
        return nil
    }

    /// "web.whatsapp.com" → "whatsapp": the part that names the site, to tell its own links from the others.
    static func registrableName(_ host: String?) -> String {
        let parts = (host ?? "").lowercased().split(separator: ".").map(String.init)
        return parts.count >= 2 ? parts[parts.count - 2] : (parts.first ?? "")
    }
}
