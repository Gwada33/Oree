import AppKit
import WebKit
import BrowserCore

/// « Aperçu » d'un lien (⌥-clic, ou clic droit › Aperçu du lien) : une carte au-dessus de la page, qui charge le lien sans quitter l'onglet.
/// Fond sombre cliquable, Échap ou « Fermer » la ferme ; « Ouvrir dans un onglet » la garde ; « Mini-fenêtre » la détache.
/// Sa page vit dans la même configuration que les onglets (même magasin, mêmes bloqueurs), et elle n'ouvre jamais de fenêtre.
@MainActor
final class PeekPanelView: NSView, WKNavigationDelegate {
    private let card = SurfaceView(fill: Theme.page, cornerRadius: Theme.radiusLarge + 4)
    private var web: WKWebView?
    private let titleLabel = oreeLabel("", font: Theme.sans(13, .semibold), color: Theme.text)
    private let hostLabel = oreeLabel("", font: Theme.sans(11.5), color: Theme.muted)
    private let bar = SurfaceView(fill: Theme.chrome)
    private let clip = SurfaceView(cornerRadius: Theme.radiusLarge + 4)
    private var keyMonitor: Any?
    private var observation: NSKeyValueObservation?

    /// Ce que montre l'aperçu en ce moment (l'adresse peut changer si on suit un lien dedans).
    private(set) var currentURL: URL?
    var onOpenInTab: ((URL) -> Void)?
    var onOpenInMini: ((URL) -> Void)?
    var isShown: Bool { !isHidden }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        isHidden = true
        card.border = Theme.line
        card.elevation = .three
        card.clips = false
        card.translatesAutoresizingMaskIntoConstraints = false
        clip.clips = true
        clip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        card.addSubview(clip)
        clip.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let tab = TextButton("Ouvrir dans un onglet", style: .primary) { [weak self] in
            guard let self, let url = self.currentURL else { return }
            self.close(); self.onOpenInTab?(url)
        }
        let mini = TextButton("Mini-fenêtre", style: .secondary) { [weak self] in
            guard let self, let url = self.currentURL else { return }
            self.close(); self.onOpenInMini?(url)
        }
        let closeButton = TextButton("Fermer", style: .secondary) { [weak self] in self?.close() }
        titleLabel.lineBreakMode = .byTruncatingTail
        hostLabel.lineBreakMode = .byTruncatingTail
        let texts = NSStackView(views: [titleLabel, hostLabel])
        texts.orientation = .vertical; texts.alignment = .leading; texts.spacing = 1
        let buttons = NSStackView(views: [closeButton, mini, tab])
        buttons.orientation = .horizontal; buttons.spacing = 8
        for view in [texts, buttons] { view.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(view) }
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor), card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.78), card.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.84),
            clip.topAnchor.constraint(equalTo: card.topAnchor), clip.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            clip.leadingAnchor.constraint(equalTo: card.leadingAnchor), clip.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            bar.topAnchor.constraint(equalTo: clip.topAnchor), bar.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: clip.trailingAnchor), bar.heightAnchor.constraint(equalToConstant: 52),
            texts.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 18), texts.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12), buttons.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -12),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.black.withAlphaComponent(effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.55 : 0.34).cgColor
    }
    override var wantsUpdateLayer: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { close() }
    }

    /// Charge `url` dans une page neuve (configuration des onglets) et montre la carte.
    func show(_ url: URL, configuration: WKWebViewConfiguration) {
        tearDownPage()
        let page = WKWebView(frame: .zero, configuration: configuration)
        page.translatesAutoresizingMaskIntoConstraints = false
        page.navigationDelegate = self
        page.allowsBackForwardNavigationGestures = true
        clip.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: bar.bottomAnchor), page.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: clip.trailingAnchor), page.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
        ])
        web = page
        observation = page.observe(\.title) { [weak self] page, _ in MainActor.assumeIsolated { self?.titleLabel.stringValue = page.title ?? "" } }
        currentURL = url
        titleLabel.stringValue = url.host ?? url.absoluteString
        hostLabel.stringValue = url.host ?? ""
        page.load(URLRequest(url: url))
        guard isHidden else { return }
        isHidden = false
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.16; animator().alphaValue = 1 }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self.close() }
            return nil
        }
    }

    func close() {
        guard !isHidden else { return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.14; animator().alphaValue = 0 }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue == 0 else { return }
                self.isHidden = true
                self.tearDownPage()                                     // frees the page and anything it was playing
            }
        })
    }

    /// What the card looks like (PNG), for automation.
    func snapshot(to path: String) async {
        alphaValue = 1
        layoutSubtreeIfNeeded()
        guard let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else { return }
        card.cacheDisplay(in: card.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private func tearDownPage() {
        observation = nil
        web?.stopLoading()
        web?.navigationDelegate = nil
        web?.removeFromSuperview()
        web = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url { currentURL = url; hostLabel.stringValue = url.host ?? "" }
    }
}
