import AppKit
import BrowserCore

/// One row in the sidebar's tab list: site badge, title, close button
/// (revealed on hover / for the active tab). Selection and hover are drawn
/// on a sublayer so they cross-fade instead of snapping.
final class TabButtonView: NSView {
    private let badge = LetterBadgeView(size: 18, cornerRadius: 5)
    private let spinner = SpinnerRingView()
    private let moon = NSImageView()
    private var isSleeping = false
    private var isLoading = false
    private var badgeLeading: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!
    private var widthConstraint: NSLayoutConstraint?
    /// In the horizontal strip: fixed width, no drag-reorder.
    private(set) var isHorizontal = false
    private let guide = CALayer()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let audioButton = NSButton()
    private var audioWidth: NSLayoutConstraint!
    private let highlight = CALayer()
    private var isHovered = false

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onToggleMute: (() -> Void)?
    /// Right-click menu, built on demand for this tab.
    var contextMenuProvider: (() -> NSMenu?)?
    /// Called after a drag with how many rows to move (negative = up).
    var onReorder: ((Int) -> Void)?

    private var dragStartY: CGFloat?
    private var dragOffset: CGFloat = 0
    private var isDragging = false
    /// Row height (36) + stack spacing (2).
    private static var rowPitch: CGFloat { Theme.rowHeight + 2 }

    var isActive = false {
        didSet { updateAppearance(animated: true) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        highlight.cornerRadius = Theme.radiusSmall + 2
        highlight.opacity = 0
        layer?.addSublayer(highlight)

        titleLabel.font = Theme.sans(13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textColor = Theme.secondaryText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.contentTintColor = Theme.tertiaryText
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setAccessibilityLabel("Fermer l'onglet")
        closeButton.alphaValue = 0

        audioButton.isBordered = false
        audioButton.imageScaling = .scaleProportionallyDown
        audioButton.target = self
        audioButton.action = #selector(audioTapped)
        audioButton.translatesAutoresizingMaskIntoConstraints = false
        audioButton.isHidden = true

        moon.image = .oreeSymbol("moon", size: 10, weight: .medium) { Theme.muted }
        moon.translatesAutoresizingMaskIntoConstraints = false
        moon.isHidden = true
        addSubview(badge)
        addSubview(spinner)
        addSubview(moon)
        addSubview(titleLabel)
        addSubview(audioButton)
        addSubview(closeButton)

        heightConstraint = heightAnchor.constraint(equalToConstant: Theme.rowHeight)
        heightConstraint.isActive = true
        badgeLeading = badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9)
        badgeLeading.isActive = true
        NSLayoutConstraint.activate([
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),

            spinner.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            moon.trailingAnchor.constraint(equalTo: audioButton.leadingAnchor, constant: -2),
            moon.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: moon.leadingAnchor, constant: -4),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: audioButton.leadingAnchor, constant: -4),

            audioButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            audioButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            audioButton.heightAnchor.constraint(equalToConstant: 18),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),

        ])

        audioWidth = audioButton.widthAnchor.constraint(equalToConstant: 0)
        audioWidth.isActive = true

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAppearance(animated: false)
    }

    /// Re-reads density, radius and text size after the user changed them.
    func refreshMetrics() {
        heightConstraint.constant = Theme.rowHeight
        highlight.cornerRadius = Theme.radiusSmall + 2
        updateAppearance(animated: false)
        needsLayout = true
    }

    /// Switches between a full-width sidebar row and a 190 pt chip of the horizontal strip.
    func setHorizontal(_ horizontal: Bool) {
        isHorizontal = horizontal
        widthConstraint?.isActive = false
        widthConstraint = nil
        if horizontal {
            let w = widthAnchor.constraint(equalToConstant: 190)
            w.isActive = true
            widthConstraint = w
        }
    }

    /// Tabs inside a group sit 14 pt in, with a thin guide line on the left.
    func setIndented(_ indented: Bool) {
        badgeLeading.constant = indented ? 23 : 9
        guide.isHidden = !indented
        if indented, guide.superlayer == nil { layer?.insertSublayer(guide, at: 0) }
        guide.backgroundColor = Theme.cg(Theme.line, in: self)
        needsLayout = true
    }

    /// Shows the speaker (playing) or the crossed-out speaker (muted); nothing otherwise.
    func setAudio(_ state: Tab.AudioState) {
        let symbol: String?
        switch state {
        case .none: symbol = nil
        case .playing: symbol = "speaker.wave.2.fill"
        case .muted: symbol = "speaker.slash.fill"
        }
        audioButton.isHidden = symbol == nil
        audioWidth.constant = symbol == nil ? 0 : 18
        if let symbol {
            audioButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            audioButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            audioButton.contentTintColor = state == .playing ? Theme.accent : Theme.tertiaryText
            audioButton.setAccessibilityLabel(state == .playing ? "Couper le son de l'onglet" : "Réactiver le son de l'onglet")
        }
    }

    @objc private func audioTapped() { onToggleMute?() }

    /// Sleeping tab: grey title, desaturated half-transparent favicon, moon.
    func setSleeping(_ sleeping: Bool) {
        isSleeping = sleeping
        moon.isHidden = !sleeping
        badge.alphaValue = sleeping ? 0.5 : 1
        badge.layer?.filters = sleeping ? [Self.desaturate] : nil
        updateAppearance(animated: false)
    }

    private static let desaturate: CIFilter = {
        let f = CIFilter(name: "CIColorControls")!
        f.setValue(0, forKey: "inputSaturation")
        return f
    }()

    /// Loading ring replaces the favicon while the page loads, in the space color.
    func setLoading(_ loading: Bool, hue: OreeTokens.Hue) {
        isLoading = loading
        spinner.color = Theme.hue(hue)
        spinner.setSpinning(loading)
        badge.isHidden = loading
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTitle(_ title: String, host: String) {
        titleLabel.stringValue = title
        let identity = host.isEmpty ? title : host
        badge.configureFavicon(host: identity, fallbackText: identity)
        setAccessibilityLabel(title)
    }

    // MARK: Entry / exit animations

    /// Fades and slides the row in from the left.
    func animateIn() {
        alphaValue = 0
        if !Motion.reduced {   // reduced motion: fade only, no sliding
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = -14
            slide.toValue = 0
            slide.duration = Motion.standard
            slide.timingFunction = Motion.timing
            layer?.add(slide, forKey: "slideIn")
        }
        Motion.animate(Motion.standard) { animator().alphaValue = 1 }
    }

    func animateOut(completion: @escaping @MainActor () -> Void) {
        Motion.animate(Motion.quick, { animator().alphaValue = 0 }, completion: completion)
    }

    // MARK: Interaction

    @objc private func closeTapped() { onClose?() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStartY = event.locationInWindow.y
        isDragging = false
        onSelect?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isHorizontal, let start = dragStartY else { return }
        let delta = event.locationInWindow.y - start
        if !isDragging && abs(delta) > 5 {
            isDragging = true
            layer?.zPosition = 10
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.4
            layer?.shadowRadius = 8
            layer?.shadowOffset = CGSize(width: 0, height: -2)
        }
        guard isDragging else { return }
        // The row follows the pointer; it drops into place on mouse-up.
        dragOffset = delta
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.transform = CATransform3DMakeTranslation(0, isFlippedGeometry ? -delta : delta, 0)
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStartY = nil }
        guard isDragging else { return }
        isDragging = false
        // Moving the pointer up (positive window-y) means earlier in the list.
        let steps = -Int((dragOffset / Self.rowPitch).rounded())
        Motion.transaction(Motion.standard) {
            layer?.transform = CATransform3DIdentity
            layer?.shadowOpacity = 0
            layer?.zPosition = 0
        }
        if steps != 0 { onReorder?(steps) }
    }

    private var isFlippedGeometry: Bool { layer?.isGeometryFlipped ?? false }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenuProvider?() }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = bounds
        guide.frame = CGRect(x: 8, y: 0, width: 1, height: bounds.height)
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance(animated: false)
        guide.backgroundColor = Theme.cg(Theme.line, in: self)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; updateAppearance(animated: true) }
    override func mouseExited(with event: NSEvent) { isHovered = false; updateAppearance(animated: true) }

    private func updateAppearance(animated: Bool) {
        let target: (color: NSColor, opacity: Float) = isActive
            ? (Theme.raised, 1)
            : (Theme.hover, isHovered ? 1 : 0)
        Motion.transaction(animated ? Motion.quick : 0, disableActions: !animated) {
            highlight.backgroundColor = Theme.cg(target.color, in: self)
            highlight.opacity = target.opacity
        }

        if isActive { Theme.apply(.one, to: highlight) } else { highlight.shadowOpacity = 0 }
        titleLabel.textColor = isSleeping ? Theme.muted : (isActive ? Theme.text : Theme.muted)
        titleLabel.font = Theme.sans(13, isActive ? .semibold : .regular)
        let showClose = isActive || isHovered
        if animated {
            Motion.animate(Motion.quick) { closeButton.animator().alphaValue = showClose ? 1 : 0 }
        } else {
            closeButton.alphaValue = showClose ? 1 : 0
        }
        setAccessibilityValue(isActive ? "Onglet actif" : nil)
    }
}
