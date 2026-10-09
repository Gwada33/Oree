import AppKit
import BrowserCore

/// First-run welcome in three steps: sidebar layout, theme + accent, and importing favorites
/// from the browsers found on this Mac. Every choice applies live and can be changed later in
/// « Personnaliser ». Skippable at any time.
@MainActor
final class OnboardingView: NSView {
    var onChange: (() -> Void)?
    var onFinish: (() -> Void)?
    /// Imports favorites from a browser, returns how many were added.
    var onImport: ((SourceBrowser) -> Int)?

    private let card = SurfaceView(fill: Theme.raised, cornerRadius: Theme.radiusLarge + 4)
    private let content = NSStackView()
    private var step = 0
    private let store = SettingsStore.shared
    private var importMessages: [SourceBrowser: String] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        let scrim = SurfaceView(fill: Theme.chrome)
        scrim.alphaValue = 0.97
        addSubview(scrim)
        card.elevation = .three
        card.border = Theme.line
        addSubview(card)
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            scrim.topAnchor.constraint(equalTo: topAnchor), scrim.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: leadingAnchor), scrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.centerXAnchor.constraint(equalTo: centerXAnchor), card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 520),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 32),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 32),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -32),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -28),
        ])
        card.setAccessibilityElement(true); card.setAccessibilityRole(.group); card.setAccessibilityLabel("Bienvenue")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        step = 0; render(); isHidden = false
        alphaValue = 0
        Motion.animate(Motion.slow) { animator().alphaValue = 1 }
    }

    private func finish() {
        store.onboardingDone = true
        Motion.animate(Motion.standard, { animator().alphaValue = 0 }, completion: { [weak self] in self?.isHidden = true })
        onFinish?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }
    override func mouseDown(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Steps

    private func render() {
        content.arrangedSubviews.forEach { content.removeArrangedSubview($0); $0.removeFromSuperview() }
        let dots = oreeLabel("Étape \(step + 1) sur 3", font: Theme.sans(12, .semibold), color: Theme.muted)
        content.addArrangedSubview(dots)
        switch step {
        case 0: stepLayout()
        case 1: stepTheme()
        default: stepImport()
        }
        let skip = TextButton("Passer", style: .ghost) { [weak self] in self?.finish() }
        let next = TextButton(step == 2 ? "Terminer" : "Continuer", style: .primary) { [weak self] in
            guard let self else { return }
            if self.step == 2 { self.finish() } else { self.step += 1; self.render() }
        }
        var buttons: [NSView] = [skip, NSView(), next]
        if step > 0 { buttons.insert(TextButton("Retour", style: .secondary) { [weak self] in self?.step -= 1; self?.render() }, at: 1) }
        let row = NSStackView(views: buttons); row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY
        content.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }

    private func heading(_ title: String, _ subtitle: String) {
        content.addArrangedSubview(oreeLabel(title, font: Theme.serifItalic(40), color: Theme.text))
        let sub = oreeLabel(subtitle, font: Theme.sans(14), color: Theme.muted, lines: 3)
        content.addArrangedSubview(sub)
        sub.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }

    private func stepLayout() {
        heading("Bienvenue", "Où voulez-vous vos onglets ? Vous pourrez changer cela à tout moment.")
        let current = store.tabLayout == .horizontal ? 2 : (store.sidebarMode == .compact ? 1 : 0)
        let seg = SegmentedPills(options: ["Barre latérale", "Icônes seules", "Onglets en haut"], selected: current) { [weak self] i in
            guard let self else { return }
            self.store.tabLayout = i == 2 ? .horizontal : .vertical
            if i < 2 { self.store.sidebarMode = i == 1 ? .compact : .fixed }
            self.onChange?()
        }
        content.addArrangedSubview(seg)
        seg.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }

    private func stepTheme() {
        heading("Votre ambiance", "Clair, sombre, ou selon le réglage de votre Mac — et une couleur d’accent.")
        let theme = SegmentedPills(options: AppearanceMode.allCases.map(\.label), selected: AppearanceMode.allCases.firstIndex(of: store.appearanceMode) ?? 2) { [weak self] i in
            self?.store.appearanceMode = AppearanceMode.allCases[i]; self?.onChange?()
        }
        content.addArrangedSubview(theme)
        theme.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        let accent = SwatchRow(selected: store.accentHue) { [weak self] hue in self?.store.accentHue = hue; self?.onChange?() }
        content.addArrangedSubview(accent)
    }

    private func stepImport() {
        heading("Vos favoris", "Reprenez vos favoris depuis un autre navigateur. Seuls les favoris sont importés : ni mots de passe, ni historique.")
        let found = BrowserImporter.detectInstalledBrowsers()
        if found.isEmpty {
            content.addArrangedSubview(oreeLabel("Aucun autre navigateur trouvé sur ce Mac. Vous pourrez ajouter des favoris à la main.", font: Theme.sans(13), color: Theme.muted, lines: 2))
        }
        for browser in found {
            let status = oreeLabel(importMessages[browser] ?? "", font: Theme.sans(12), color: Theme.muted)
            let button = TextButton("Importer", style: .secondary) { [weak self] in
                guard let self else { return }
                let count = self.onImport?(browser) ?? 0
                self.importMessages[browser] = count == 0 ? "Aucun favori trouvé" : "\(count) favori\(count > 1 ? "s" : "") importé\(count > 1 ? "s" : "")"
                self.render()
            }
            let row = oreeSettingRow(title: browser.displayName, control: NSStackView(views: [status, button]))
            content.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
    }
}
