import AppKit
import BrowserCore

/// « Centre de personnalisation »: a drawer sliding in from the right with every look-and-feel
/// choice (presets, theme, accent, sidebar, density, radius, text size, home page, motion).
/// Every control writes to `SettingsStore` and calls `onChange`, so the window updates live.
@MainActor
final class CustomizeDrawerView: NSView {
    var onChange: (() -> Void)?
    var onClose: (() -> Void)?
    var onPickPhoto: (() -> Void)?

    private let scrim = NSView()
    private let panel = SurfaceView(fill: Theme.raised, cornerRadius: 0)
    private var panelTrailing: NSLayoutConstraint!
    private let panelWidth: CGFloat = 372
    private var presetRows: [(ThemePreset, PresetRow)] = []
    private var controls: [String: NSView] = [:]
    private var photoRow: NSView?
    private let store = SettingsStore.shared

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        setAccessibilityElement(false)

        scrim.wantsLayer = true
        scrim.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrim)
        panel.elevation = .three
        panel.border = Theme.line
        addSubview(panel)
        panelTrailing = panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: panelWidth)
        NSLayoutConstraint.activate([
            scrim.topAnchor.constraint(equalTo: topAnchor), scrim.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: leadingAnchor), scrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor), panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.widthAnchor.constraint(equalToConstant: panelWidth), panelTrailing,
        ])
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.group)
        panel.setAccessibilityLabel("Personnaliser")
        buildContent()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
    }

    // MARK: Show / hide

    func present() {
        refreshFromSettings()
        isHidden = false
        scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        scrim.alphaValue = 0
        layoutSubtreeIfNeeded()
        Motion.animate(Motion.slow) {
            scrim.animator().alphaValue = 1
            panelTrailing.animator().constant = 0
            layoutSubtreeIfNeeded()
        }
    }

    func dismiss() {
        Motion.animate(Motion.standard, {
            scrim.animator().alphaValue = 0
            panelTrailing.animator().constant = panelWidth
            layoutSubtreeIfNeeded()
        }, completion: { [weak self] in self?.isHidden = true })
    }

    var isPresented: Bool { !isHidden }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !panel.frame.contains(p) { onClose?() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cancelOperation(_ sender: Any?) { onClose?() }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) } }

    // MARK: Content

    private func changed() { onChange?() }

    private func section(_ title: String) -> NSView {
        let l = oreeLabel(title.uppercased(), font: Theme.sans(11, .semibold), color: Theme.muted)
        return l
    }

    private func buildContent() {
        let title = oreeLabel("Personnaliser", font: Theme.Typo.heading, color: Theme.text)
        let close = ChromeIconButton(symbol: "xmark", label: "Fermer", size: 28, pointSize: 12)
        close.onClick = { [weak self] in self?.onClose?() }
        let header = NSStackView(views: [title, close])
        header.orientation = .horizontal; header.alignment = .centerY; header.distribution = .fill
        header.translatesAutoresizingMaskIntoConstraints = false

        var items: [NSView] = [header]

        // Presets
        items.append(section("Préréglages"))
        for preset in ThemePreset.all {
            let row = PresetRow(preset: preset)
            row.onClick = { [weak self] in
                preset.apply(to: self?.store ?? .shared)
                self?.refreshFromSettings()
                self?.changed()
            }
            presetRows.append((preset, row))
            items.append(row)
        }

        // Theme
        items.append(section("Thème"))
        let theme = SegmentedPills(options: AppearanceMode.allCases.map(\.label), selected: AppearanceMode.allCases.firstIndex(of: store.appearanceMode) ?? 2) { [weak self] i in
            self?.store.appearanceMode = AppearanceMode.allCases[i]; self?.changed()
        }
        controls["theme"] = theme; items.append(theme)

        items.append(section("Couleur d’accent"))
        let accent = SwatchRow(selected: store.accentHue) { [weak self] hue in self?.store.accentHue = hue; self?.changed() }
        controls["accent"] = accent; items.append(accent)

        items.append(section("Onglets"))
        let layouts = TabLayout.allCases
        let layout = SegmentedPills(options: layouts.map(\.label), selected: layouts.firstIndex(of: store.tabLayout) ?? 0) { [weak self] i in
            self?.store.tabLayout = layouts[i]; self?.changed()
        }
        controls["layout"] = layout; items.append(layout)

        items.append(section("Barre latérale"))
        let modes: [SidebarMode] = [.fixed, .compact, .floating, .hidden]
        let sidebar = SegmentedPills(options: modes.map(\.label), selected: modes.firstIndex(of: store.sidebarMode) ?? 0) { [weak self] i in
            self?.store.sidebarMode = modes[i]; self?.changed()
        }
        controls["sidebar"] = sidebar; items.append(sidebar)

        let hint = oreeLabel("Au survol : la barre est cachée et apparaît, en verre, quand le pointeur touche le bord gauche. Tirez le bord de la barre pour la redimensionner.", font: Theme.sans(11.5), color: Theme.muted, lines: 4)
        items.append(hint)
        let glassSwitch = SwitchToggle(isOn: store.sidebarGlass, label: "Effet verre (Liquid Glass)") { [weak self] on in self?.store.sidebarGlass = on; self?.changed() }
        controls["glass"] = glassSwitch
        items.append(oreeSettingRow(title: "Effet verre (Liquid Glass)", detail: "Barre translucide en mode « Au survol ».", control: glassSwitch))

        items.append(section("Densité"))
        let densities = OreeTokens.Density.allCases
        let density = SegmentedPills(options: densities.map(\.label), selected: densities.firstIndex(of: store.density) ?? 1) { [weak self] i in
            self?.store.density = densities[i]; self?.changed()
        }
        controls["density"] = density; items.append(density)

        items.append(section("Arrondi des angles"))
        let slider = NSSlider(value: store.cornerRadius, minValue: 0, maxValue: 16, target: self, action: #selector(radiusChanged(_:)))
        slider.numberOfTickMarks = 9
        slider.allowsTickMarkValuesOnly = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.setAccessibilityLabel("Arrondi des angles")
        controls["radius"] = slider; items.append(slider)

        items.append(section("Taille du texte de l’interface"))
        let sizes = [-1, 0, 1]
        let text = SegmentedPills(options: ["Petit", "Moyen", "Grand"], selected: sizes.firstIndex(of: store.uiTextOffset) ?? 1) { [weak self] i in
            self?.store.uiTextOffset = sizes[i]; self?.changed()
        }
        controls["text"] = text; items.append(text)

        items.append(section("Page d’accueil"))
        let backgrounds = HomeBackground.allCases
        let bg = SegmentedPills(options: backgrounds.map(\.label), selected: backgrounds.firstIndex(of: store.homeBackground) ?? 0) { [weak self] i in
            self?.store.homeBackground = backgrounds[i]
            self?.photoRow?.isHidden = backgrounds[i] != .photo
            self?.changed()
        }
        controls["background"] = bg; items.append(bg)
        let pick = TextButton("Choisir une photo…") { [weak self] in self?.onPickPhoto?() }
        let photo = NSStackView(views: [pick]); photo.orientation = .horizontal; photo.alignment = .centerY
        photo.translatesAutoresizingMaskIntoConstraints = false
        photoRow = photo; items.append(photo)

        @MainActor func toggle(_ key: String, _ title: String, _ get: @escaping @MainActor () -> Bool, _ set: @escaping @MainActor (Bool) -> Void) {
            let s = SwitchToggle(isOn: get(), label: title) { [weak self] on in set(on); self?.changed() }
            controls[key] = s
            items.append(oreeSettingRow(title: title, control: s))
        }
        toggle("favs", "Favoris", { self.store.homeShowsFavorites }, { self.store.homeShowsFavorites = $0 })
        toggle("recent", "Reprendre", { self.store.startPageShowsRecent }, { self.store.startPageShowsRecent = $0 })
        toggle("spaces", "Espaces", { self.store.homeShowsSpaces }, { self.store.homeShowsSpaces = $0 })

        items.append(section("Mouvement"))
        toggle("calm", "Réduire les animations", { self.store.calmMotion }, { self.store.calmMotion = $0 })

        let stack = NSStackView(views: items)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 10
        stack.setCustomSpacing(18, after: header)
        for (i, v) in items.enumerated() where v is NSTextField && i > 0 { stack.setCustomSpacing(6, after: v) }
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let doc = FlippedDocumentView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        doc.addSubview(stack)
        panel.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -24),
        ])
    }

    @objc private func radiusChanged(_ sender: NSSlider) {
        store.cornerRadius = (sender.doubleValue / 2).rounded() * 2
        changed()
    }

    /// Re-reads every value (after a preset, or when the drawer opens).
    func refreshFromSettings() {
        (controls["theme"] as? SegmentedPills)?.select(AppearanceMode.allCases.firstIndex(of: store.appearanceMode) ?? 2)
        (controls["accent"] as? SwatchRow)?.select(store.accentHue)
        (controls["layout"] as? SegmentedPills)?.select(TabLayout.allCases.firstIndex(of: store.tabLayout) ?? 0)
        (controls["sidebar"] as? SegmentedPills)?.select([SidebarMode.fixed, .compact, .floating, .hidden].firstIndex(of: store.sidebarMode) ?? 0)
        (controls["glass"] as? SwitchToggle)?.set(store.sidebarGlass)
        (controls["density"] as? SegmentedPills)?.select(OreeTokens.Density.allCases.firstIndex(of: store.density) ?? 1)
        (controls["radius"] as? NSSlider)?.doubleValue = store.cornerRadius
        (controls["text"] as? SegmentedPills)?.select([-1, 0, 1].firstIndex(of: store.uiTextOffset) ?? 1)
        (controls["background"] as? SegmentedPills)?.select(HomeBackground.allCases.firstIndex(of: store.homeBackground) ?? 0)
        photoRow?.isHidden = store.homeBackground != .photo
        (controls["favs"] as? SwitchToggle)?.set(store.homeShowsFavorites)
        (controls["recent"] as? SwitchToggle)?.set(store.startPageShowsRecent)
        (controls["spaces"] as? SwitchToggle)?.set(store.homeShowsSpaces)
        (controls["calm"] as? SwitchToggle)?.set(store.calmMotion)
        for (preset, row) in presetRows { row.isCurrent = preset.matches(store) }
    }
}

/// One preset card: name + one-line summary, ringed when it matches the current settings.
@MainActor
private final class PresetRow: NSView {
    var onClick: (() -> Void)?
    var isCurrent = false { didSet { needsDisplay = true } }
    private let preset: ThemePreset
    private var hovered = false { didSet { needsDisplay = true } }

    init(preset: ThemePreset) {
        self.preset = preset
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 46).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Préréglage \(preset.name), \(preset.summary)")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: Theme.radius, yRadius: Theme.radius)
        (hovered ? Theme.hover : Theme.field.withAlphaComponent(0.5)).setFill(); path.fill()
        if isCurrent { Theme.accent.setStroke(); path.lineWidth = 2; path.stroke() }
        // Swatch of the preset's accent
        Theme.hue(preset.accent).setFill()
        NSBezierPath(ovalIn: NSRect(x: 14, y: bounds.midY - 7, width: 14, height: 14)).fill()
        NSAttributedString(string: preset.name, attributes: [.font: Theme.sans(13, .semibold), .foregroundColor: Theme.text])
            .draw(at: NSPoint(x: 40, y: bounds.midY + 1))
        NSAttributedString(string: preset.summary, attributes: [.font: Theme.sans(11.5), .foregroundColor: Theme.muted])
            .draw(at: NSPoint(x: 40, y: bounds.midY - 16))
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
