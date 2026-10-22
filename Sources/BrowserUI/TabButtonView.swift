import AppKit
import BrowserCore

/// One row in the sidebar's tab list: site badge, title, close button
/// (revealed on hover / for the active tab). Selection and hover are drawn
/// on a sublayer so they cross-fade instead of snapping.
final class TabButtonView: NSView {
    private let badge = LetterBadgeView(size: 18, cornerRadius: 5)
    private let spinner = SpinnerRingView()
    private var isSleeping = false
    private var isFrozen = false
    private(set) var isLoading = false
    private var badgeLeading: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!
    private var widthConstraint: NSLayoutConstraint?
    /// In the horizontal strip: fixed width, no drag-reorder.
    private(set) var isHorizontal = false
    private var isIndented = false
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

    private var dragStart: CGFloat?
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

        addSubview(badge)
        addSubview(spinner)
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
            titleLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
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
        // Unchanged: leave the width alone (re-creating the constraint at each list rebuild cost most of its time, and reset a width the strip had animated).
        if horizontal == isHorizontal, (widthConstraint != nil) == horizontal { return }
        isHorizontal = horizontal
        widthConstraint?.isActive = false
        widthConstraint = nil
        if horizontal {
            let w = widthAnchor.constraint(equalToConstant: 190)
            w.isActive = true
            widthConstraint = w
        }
    }

    /// Width of this chip in the horizontal strip (the strip shares its width between the tabs, 190 pt at most).
    func setStripWidth(_ width: CGFloat) {
        guard isHorizontal, let widthConstraint, abs(widthConstraint.constant - width) > 0.5 else { return }
        if window != nil, superview != nil { Motion.animate(Motion.quick) { widthConstraint.animator().constant = width } }
        else { widthConstraint.constant = width }
    }

    /// Tabs inside a group sit 14 pt in, with a thin guide line on the left.
    func setIndented(_ indented: Bool) {
        guard indented != isIndented else { return }
        isIndented = indented
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

    /// Sleeping/frozen tabs look exactly like awake ones: hibernation must be invisible (no moon, no grey, no dimmed favicon).
    /// The state is only kept for behaviour (hover pre-wake).
    func setSleeping(_ sleeping: Bool) { isSleeping = sleeping }

    func setFrozen(_ frozen: Bool) { isFrozen = frozen }

    /// Fires once the pointer has rested on a sleeping tab for a moment — the app wakes it ahead of the click.
    var onHoverDwell: (() -> Void)?
    private var dwellWork: DispatchWorkItem?

    /// The pointer has rested on the tab for a moment (true), or left it (false): the window shows or hides the preview card.
    var onHoverPreview: ((Bool) -> Void)?
    /// Le pointeur quitte l'onglet après l'avoir survolé : combien de temps, si la carte d'aperçu s'est affichée, si l'on a cliqué (journal d'événements).
    var onHoverEnd: ((_ dwellMs: Int, _ previewed: Bool, _ clicked: Bool) -> Void)?
    private var hoverStart: Date?
    private var hoverPreviewed = false
    private var hoverClicked = false
    private var previewWork: DispatchWorkItem?

    private func startPreview() {
        previewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in mainActorNow { if self?.isHovered == true { self?.hoverPreviewed = true; self?.onHoverPreview?(true) } } }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    private func startDwell() {
        dwellWork?.cancel()
        guard isSleeping else { return }
        let work = DispatchWorkItem { [weak self] in mainActorNow { if self?.isHovered == true { self?.onHoverDwell?() } } }
        dwellWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

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

    /// Closing: the row shrinks a little and fades, the way the system closes things; the rows below it then spring up into the gap.
    func animateOut(completion: @escaping @MainActor () -> Void) {
        guard let layer, !Motion.reduced else { Motion.animate(Motion.quick, { animator().alphaValue = 0 }, completion: completion); return }
        let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = 1; scale.toValue = 0.88
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
        let group = CAAnimationGroup(); group.animations = [scale, fade]; group.duration = 0.16
        group.timingFunction = CAMediaTimingFunction(name: .easeIn); group.fillMode = .forwards; group.isRemovedOnCompletion = false
        layer.add(group, forKey: "oreeClose")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { mainActorNow { completion() } }
    }

    // MARK: Interaction

    @objc private func closeTapped() { onClose?() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        previewWork?.cancel(); onHoverPreview?(false)
        hoverClicked = true
        dragStart = isHorizontal ? event.locationInWindow.x : event.locationInWindow.y
        isDragging = false
        onSelect?()
    }

    /// The tabs of the same list (sidebar or strip), in order, and the distance between two neighbours.
    private var peers: [TabButtonView] { (superview as? NSStackView)?.arrangedSubviews.compactMap { $0 as? TabButtonView }.filter { !$0.isHidden } ?? [] }
    private var pitch: CGFloat {
        let all = peers
        guard let me = all.firstIndex(where: { $0 === self }) else { return isHorizontal ? bounds.width + 3 : Self.rowPitch }
        let other = me + 1 < all.count ? all[me + 1] : (me > 0 ? all[me - 1] : nil)
        guard let other else { return isHorizontal ? bounds.width + 3 : Self.rowPitch }
        return isHorizontal ? abs(other.frame.minX - frame.minX) : abs(other.frame.minY - frame.minY)
    }
    /// A move along the list's axis, positive = down / right, in the layer's own coordinates.
    private func translation(_ screen: CGFloat) -> CATransform3D {
        isHorizontal ? CATransform3DMakeTranslation(screen, 0, 0) : CATransform3DMakeTranslation(0, isFlippedGeometry ? screen : -screen, 0)
    }
    private var lastSlot = 0

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let delta = (isHorizontal ? event.locationInWindow.x : event.locationInWindow.y) - start
        if !isDragging && abs(delta) > 5 {
            isDragging = true
            lastSlot = 0
            layer?.zPosition = 10
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowRadius = 10
            layer?.shadowOffset = CGSize(width: 0, height: -3)
            TabMotion.lift(self, true)
        }
        guard isDragging else { return }
        // The row follows the pointer, a touch larger; the others slide aside to open the slot it would drop into.
        dragOffset = delta
        let screen = isHorizontal ? delta : -delta
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var lifted = translation(screen)
        lifted = CATransform3DScale(lifted, 1.03, 1.03, 1)
        layer?.transform = lifted
        CATransaction.commit()

        let all = peers
        guard let me = all.firstIndex(where: { $0 === self }) else { return }
        let slot = max(-me, min(all.count - 1 - me, Int((screen / pitch).rounded())))
        guard slot != lastSlot else { return }
        lastSlot = slot
        for (index, peer) in all.enumerated() where peer !== self {
            let shift: CGFloat = (slot > 0 && index > me && index <= me + slot) ? -pitch : (slot < 0 && index < me && index >= me + slot) ? pitch : 0
            peer.slide(by: shift)
        }
    }

    /// Springs to `screen` points off its place (0 = home).
    fileprivate func slide(by screen: CGFloat) {
        guard let layer else { return }
        let from = layer.presentation()?.transform ?? layer.transform
        layer.removeAnimation(forKey: "oreeSlide")
        let target = translation(screen)
        CATransaction.begin(); CATransaction.setDisableActions(true); layer.transform = target; CATransaction.commit()
        guard !Motion.reduced else { return }
        let animation = CASpringAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: from); animation.toValue = NSValue(caTransform3D: target)
        animation.mass = 1; animation.stiffness = 360; animation.damping = 28
        animation.duration = animation.settlingDuration
        layer.add(animation, forKey: "oreeSlide")
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard isDragging else { return }
        isDragging = false
        let screen = isHorizontal ? dragOffset : -dragOffset
        let all = peers
        let me = all.firstIndex(where: { $0 === self }) ?? 0
        let steps = max(-me, min(all.count - 1 - me, Int((screen / pitch).rounded())))
        TabMotion.lift(self, false)
        if steps != 0 { onReorder?(steps) }
        // Nothing moved (dropped where it was, or the move was refused): everything springs home.
        if steps == 0 || !(superview is NSStackView) {
            for view in all { TabMotion.spring(view, fromX: 0, fromY: 0) }
            let visual = layer?.presentation()?.transform ?? CATransform3DIdentity
            TabMotion.spring(self, fromX: visual.m41, fromY: visual.m42)
        }
        layer?.zPosition = 0
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

    override func mouseEntered(with event: NSEvent) { isHovered = true; hoverStart = Date(); hoverPreviewed = false; hoverClicked = false; updateAppearance(animated: true); startDwell(); startPreview() }
    override func mouseExited(with event: NSEvent) {
        isHovered = false; dwellWork?.cancel(); previewWork?.cancel(); onHoverPreview?(false); updateAppearance(animated: true)
        if let start = hoverStart {
            hoverStart = nil
            let dwell = Int(Date().timeIntervalSince(start) * 1000)
            if dwell >= 150 { onHoverEnd?(dwell, hoverPreviewed, hoverClicked) }
        }
    }

    private func updateAppearance(animated: Bool) {
        let target: (color: NSColor, opacity: Float) = isActive
            ? (Theme.raised, 1)
            : (Theme.hover, isHovered ? 1 : 0)
        Motion.transaction(animated ? Motion.quick : 0, disableActions: !animated) {
            highlight.backgroundColor = Theme.cg(target.color, in: self)
            highlight.opacity = target.opacity
        }

        if isActive { Theme.apply(.one, to: highlight) } else { highlight.shadowOpacity = 0 }
        titleLabel.textColor = isActive ? Theme.text : Theme.muted
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
