import AppKit
import WebKit
import BrowserCore

/// "L'essentiel": a pop-up over the tab's page (a card centered on a dimmed backdrop, the page stays visible behind it), in Orée's
/// colors. Click outside, Escape or "Fermer" closes it. Its web view only ever shows HTML that `DigestRenderer` built (every text of
/// the page escaped, a strict content-security policy, no network, a non-persistent store) and refuses every navigation. JavaScript is
/// on for that page alone: it drives the servings slider.
@MainActor
final class DigestPanelView: NSView, WKNavigationDelegate {
    private let card = SurfaceView(fill: Theme.page, cornerRadius: Theme.radiusLarge + 4)
    private let web: WKWebView
    private let titleLabel = oreeLabel("L'essentiel", font: Theme.sans(13, .semibold), color: Theme.text)
    private let badge = oreeLabel("", font: Theme.sans(11.5, .medium), color: Theme.muted)
    private let busy = oreeLabel("", font: Theme.sans(14, .medium), color: Theme.muted)
    private let spinner = NSProgressIndicator()
    private let busyStack = NSStackView()
    private let cookingButton = TextButton("Mode cuisine", style: .secondary)
    private let cancelButton = TextButton("Annuler", style: .secondary)
    private let wake = ScreenWake()
    private var digest: PageDigest?
    private var notice: String?
    private var onCancel: (() -> Void)?
    private var keyMonitor: Any?
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?

    /// Called when the pop-up goes away; `true` when the user closed it (so it is not reopened by itself on this page).
    var onClose: ((_ byUser: Bool) -> Void)?
    /// The visible text of what is shown (automation).
    private(set) var shownText = ""
    private(set) var state = "closed"

    private var cooking = false {
        didSet {
            cooking ? wake.hold(reason: "Orée : mode cuisine") : wake.release()
            applySize(animated: true)
            render()
        }
    }

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(OreeSchemeHandler(), forURLScheme: "oree")      // the design system's fonts, nothing else
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        isHidden = true
        web.navigationDelegate = self
        web.translatesAutoresizingMaskIntoConstraints = false
        web.setValue(false, forKey: "drawsBackground")

        card.border = Theme.line
        card.elevation = .three
        card.clips = false
        let clip = SurfaceView(cornerRadius: Theme.radiusLarge + 4)          // rounds the web view's corners without clipping the card's shadow
        clip.clips = true
        clip.translatesAutoresizingMaskIntoConstraints = false

        let bar = SurfaceView(fill: Theme.chrome)
        let close = TextButton("Fermer", style: .primary) { [weak self] in self?.close(byUser: true) }
        cookingButton.onClick = { [weak self] in self?.cooking.toggle() }
        cancelButton.onClick = { [weak self] in self?.onCancel?() }
        for view in [titleLabel, badge, cookingButton, close] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(view) }
        spinner.style = .spinning
        spinner.controlSize = .small
        [spinner, busy, cancelButton].forEach(busyStack.addArrangedSubview)
        busyStack.orientation = .horizontal
        busyStack.spacing = 12
        busyStack.translatesAutoresizingMaskIntoConstraints = false
        busyStack.isHidden = true

        addSubview(card)
        card.addSubview(clip)
        clip.addSubview(web); clip.addSubview(bar); clip.addSubview(busyStack)
        let width = card.widthAnchor.constraint(equalToConstant: 760)
        let height = card.heightAnchor.constraint(equalToConstant: 640)
        widthConstraint = width; heightConstraint = height
        // The card never outgrows the page: its size is a wish, the margins are the rule.
        let maxWidth = card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48)
        let maxHeight = card.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, constant: -48)
        [width, height].forEach { $0.priority = .defaultHigh }
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor), card.centerYAnchor.constraint(equalTo: centerYAnchor),
            width, height, maxWidth, maxHeight,
            clip.topAnchor.constraint(equalTo: card.topAnchor), clip.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            clip.leadingAnchor.constraint(equalTo: card.leadingAnchor), clip.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            bar.topAnchor.constraint(equalTo: clip.topAnchor), bar.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: clip.trailingAnchor), bar.heightAnchor.constraint(equalToConstant: 46),
            titleLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 18), titleLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            badge.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 12), badge.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: cookingButton.leadingAnchor, constant: -12),
            close.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12), close.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            cookingButton.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8), cookingButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            web.topAnchor.constraint(equalTo: bar.bottomAnchor), web.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: clip.trailingAnchor), web.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            busyStack.centerXAnchor.constraint(equalTo: clip.centerXAnchor), busyStack.centerYAnchor.constraint(equalTo: clip.centerYAnchor),
        ])
        applySize(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func applySize(animated: Bool) {
        let width: CGFloat = cooking ? 1040 : 760, height: CGFloat = cooking ? 900 : 700
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                widthConstraint?.animator().constant = width
                heightConstraint?.animator().constant = height
            }
        } else { widthConstraint?.constant = width; heightConstraint?.constant = height }
    }

    // MARK: Backdrop

    override func updateLayer() {
        layer?.backgroundColor = NSColor.black.withAlphaComponent(effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.55 : 0.34).cgColor
    }
    override var wantsUpdateLayer: Bool { true }

    /// A click on the backdrop (outside the card) closes the pop-up.
    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { close(byUser: true) }
    }

    // MARK: States

    private func present() {
        guard isHidden else { return }
        isHidden = false
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.16; animator().alphaValue = 1 }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }          // Escape
            MainActor.assumeIsolated { self.close(byUser: true) }
            return nil
        }
    }

    /// Waiting for the page's text or the local model.
    func showBusy(_ message: String, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        busy.stringValue = message
        spinner.isHidden = false
        spinner.startAnimation(nil)
        cancelButton.isHidden = false
        busyStack.isHidden = false
        web.isHidden = true
        cookingButton.isHidden = true
        badge.stringValue = ""
        state = "busy"
        present()
    }

    func show(_ digest: PageDigest, notice: String?) {
        self.digest = digest
        self.notice = notice
        badge.stringValue = digest.source == .structured ? "Lu dans les données de la page" : "Écrit par le modèle local · peut contenir des erreurs"
        cookingButton.isHidden = digest.steps.isEmpty && digest.ingredients.isEmpty
        busyStack.isHidden = true
        spinner.stopAnimation(nil)
        web.isHidden = false
        state = "ready"
        present()
        render()
    }

    /// A plain message instead of a digest (nothing found, model unavailable, …).
    func showMessage(_ message: String) {
        digest = nil
        busy.stringValue = message
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        cancelButton.isHidden = true                                            // nothing to cancel in a message
        busyStack.isHidden = false
        web.isHidden = true
        cookingButton.isHidden = true
        badge.stringValue = ""
        state = "message"
        present()
    }

    /// `byUser`: the user chose to close it (button, Escape, click outside). Otherwise the app did (another tab, another page).
    func close(byUser: Bool = false) {
        guard !isHidden else { return }
        cooking = false
        onCancel?(); onCancel = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.14; animator().alphaValue = 0 }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue == 0 else { return }
                self.isHidden = true
                self.web.loadHTMLString("", baseURL: nil)                       // free the page
            }
        })
        state = "closed"
        onClose?(byUser)
    }

    // MARK: Automation

    func debugToggleCooking() { cooking.toggle() }
    var isScreenHeld: Bool { wake.isHeld }
    var isCooking: Bool { cooking }

    /// What the pop-up looks like (PNG), optionally scrolled.
    func snapshot(to path: String, scrollY: Int = 0) async {
        _ = await web.safeEvaluate("window.scrollTo(0, \(scrollY))", world: .defaultClient)
        try? await Task.sleep(for: .milliseconds(300))
        guard let image = try? await card.snapshotImage(), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    /// Automation: drives the servings slider the way a click on "+" would, returns the ingredient text afterwards.
    func debugSetServings(_ count: Int) async -> String {
        let script = "var s=document.getElementById('sv'); if(!s) 'no slider'; else { s.value=\(count); s.dispatchEvent(new Event('input')); Array.from(document.querySelectorAll('.t')).map(e=>e.textContent).join(' | ') + ' @ ' + document.getElementById('who').textContent }"
        return (await web.safeEvaluate(script, world: .page) as? String) ?? "error"
    }

    // MARK: Rendering

    private func render() {
        guard let digest else { return }
        let html = DigestRenderer.html(digest, style: style(), cooking: cooking, notice: notice)
        web.loadHTMLString(html, baseURL: URL(string: "oree://home/"))       // same origin as the fonts it asks for
    }

    /// The design tokens as CSS: the same variables, accent hue, fonts and radii as the start page.
    private func style() -> DigestRenderer.Style {
        let hue = SettingsStore.shared.accentHue
        let radii = OreeTokens.radii(base: SettingsStore.shared.cornerRadius)
        return .init(fontFace: StartPage.fontFaceCSS, variables: StartPage.vars(dark: false, hue: hue), darkVariables: StartPage.vars(dark: true, hue: hue),
                     radiusSmall: Int(radii.sm), radius: Int(radii.base), radiusLarge: Int(radii.lg))
    }

    // MARK: WKNavigationDelegate

    /// Only the page we loaded ourselves: a link in it (there are none) would otherwise take the pop-up away.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.navigationType == .other ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            shownText = (await webView.safeEvaluate("document.body ? document.body.innerText : ''", world: .defaultClient) as? String) ?? ""
        }
    }
}

private extension NSView {
    /// A bitmap of the view as it is drawn (subviews included; a web view's content is drawn through its own snapshot).
    func snapshotImage() async throws -> NSImage? {
        guard let web = findWeb() else { return nil }
        return try await web.takeSnapshot(configuration: nil)
    }
    private func findWeb() -> WKWebView? {
        if let web = self as? WKWebView { return web }
        for view in subviews { if let found = view.findWeb() { return found } }
        return nil
    }
}
