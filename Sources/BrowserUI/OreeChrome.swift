import AppKit
import BrowserCore

// Building blocks of the « Orée » chrome. They paint with dynamic Theme colors either in
// `draw(_:)` or `updateLayer()`, both of which AppKit re-runs when the appearance
// (light / dark) changes — so nothing here goes stale when the theme flips.

// MARK: - Helpers

extension NSImage {
    /// A symbol that is re-tinted with `color` each time it is drawn (dynamic colors resolve then).
    @MainActor
    static func oreeSymbol(_ name: String, size: CGFloat = 14, weight: NSFont.Weight = .regular, color: @escaping () -> NSColor) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return NSImage() }
        return NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            color().set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

/// A plain colored (optionally rounded / bordered / elevated) rectangle whose colors follow the theme.
@MainActor
class SurfaceView: NSView {
    var fill: NSColor? { didSet { needsDisplay = true } }
    var border: NSColor? { didSet { needsDisplay = true } }
    var borderWidth: CGFloat = 1 { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    var maskedCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner] { didSet { needsDisplay = true } }
    var elevation: Theme.Elevation? { didSet { needsDisplay = true } }
    /// Clip children to the rounded shape (disables the shadow, which would be clipped too).
    var clips = false { didSet { needsDisplay = true } }
    /// Called with true / false when the pointer enters / leaves the view (installs a tracking area).
    var onHover: ((Bool) -> Void)? { didSet { updateTrackingAreas() } }
    private var hoverArea: NSTrackingArea?

    init(fill: NSColor? = nil, cornerRadius: CGFloat = 0) {
        super.init(frame: .zero)
        self.fill = fill
        self.cornerRadius = cornerRadius
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea); self.hoverArea = nil }
        guard onHover != nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { if event.trackingArea === hoverArea { onHover?(true) } }
    override func mouseExited(with event: NSEvent) { if event.trackingArea === hoverArea { onHover?(false) } }

    override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = fill.map { Theme.cg($0, in: self) }
        layer.cornerRadius = cornerRadius
        layer.maskedCorners = maskedCorners
        layer.masksToBounds = clips
        layer.borderWidth = border == nil ? 0 : borderWidth
        layer.borderColor = border.map { Theme.cg($0, in: self) }
        if let elevation, !clips { Theme.apply(elevation, to: layer) } else { layer.shadowOpacity = 0 }
    }
}

/// A tiny key hint such as ⌘K.
@MainActor
final class KbdChip: SurfaceView {
    private let label = NSTextField(labelWithString: "")

    init(_ text: String) {
        super.init(fill: Theme.hover, cornerRadius: 5)
        label.stringValue = text
        label.font = Theme.sans(11, .medium)
        label.textColor = Theme.muted
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 18),
        ])
        // A chip is only as wide as its text, never stretched by free space around it.
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Icon button

/// 28 pt toolbar/rail button: symbol, hover wash, optional active state, tooltip.
@MainActor
final class ChromeIconButton: HoverView {
    var onClick: (() -> Void)?
    var symbol: String { didSet { refreshImage() } }
    var isActive = false { didSet { needsDisplay = true; refreshImage() } }
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.35 } }
    /// 0...1 shows a progress ring around the icon (downloads); nil = no ring; `ringIndeterminate` spins it.
    var ringProgress: Double? { didSet { updateRing() } }
    var ringIndeterminate = false { didSet { updateRing() } }
    private let ringTrack = CAShapeLayer()
    private let ringArc = CAShapeLayer()
    private let icon = NSImageView()
    private let pointSize: CGFloat

    init(symbol: String, label: String, size: CGFloat = 28, pointSize: CGFloat = 14) {
        self.symbol = symbol
        self.pointSize = pointSize
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        wantsLayer = true
        for l in [ringTrack, ringArc] { l.fillColor = nil; l.lineWidth = 1.8; l.lineCap = .round; l.isHidden = true; layer?.addSublayer(l) }
        ringArc.strokeEnd = 0
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = label
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        refreshImage()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let rect = bounds.insetBy(dx: 2.5, dy: 2.5)
        // Start at 12 o'clock, clockwise.
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: rect.width / 2, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for l in [ringTrack, ringArc] { l.frame = bounds; l.path = path }
        updateRing()
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateRing() }

    /// Draws / animates the ring (design system: 180 ms ease; rotation only when motion isn't reduced).
    private func updateRing() {
        let visible = ringProgress != nil || ringIndeterminate
        ringTrack.isHidden = !visible
        ringArc.isHidden = !visible
        ringTrack.strokeColor = Theme.cg(Theme.line, in: self)
        ringArc.strokeColor = Theme.cg(Theme.accent, in: self)
        ringArc.removeAnimation(forKey: "spin")
        guard visible else { return }
        let target = ringIndeterminate ? 0.28 : CGFloat(max(ringProgress ?? 0, 0.03))
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.reduced ? 0 : Motion.standard)
        CATransaction.setAnimationTimingFunction(Motion.timing)
        ringArc.strokeEnd = target
        CATransaction.commit()
        if ringIndeterminate, !Motion.reduced {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0; spin.toValue = -2 * Double.pi; spin.duration = 0.9; spin.repeatCount = .infinity
            ringArc.add(spin, forKey: "spin")
        }
    }

    /// A short scale "pop" (120 ms) to draw the eye, e.g. when a download starts. Skipped for reduced motion.
    func pulse() {
        guard !Motion.reduced, let layer else { return }
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1, 1.18, 1]
        pop.keyTimes = [0, 0.5, 1]
        pop.duration = Motion.quick * 2
        pop.timingFunction = Motion.timing
        layer.add(pop, forKey: "pulse")
    }

    private func refreshImage() {
        let active = isActive
        icon.image = .oreeSymbol(symbol, size: pointSize, weight: .regular) { active ? Theme.accentInk : Theme.muted }
    }

    override func draw(_ dirtyRect: NSRect) {
        let wash: NSColor? = isActive ? Theme.accentSoft : (isEnabled && hover > 0.001 ? Theme.hover.scaled(hover) : nil)
        if let wash {
            wash.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Theme.radiusSmall + 2, yRadius: Theme.radiusSmall + 2).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(superview?.convert(point, from: superview) ?? point) ? self : nil }
    override func mouseDown(with event: NSEvent) { if isEnabled { onClick?() } }
    override func accessibilityPerformPress() -> Bool { if isEnabled { onClick?() }; return isEnabled }
}

// MARK: - Spines and rail

/// A space tab on the rail: the name written vertically on a tint of the space color;
/// solid when selected. In compact mode it shrinks to the space icon.
@MainActor
final class SpineButton: HoverView {
    var onClick: (() -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?
    private(set) var space: SpaceStyle
    var isSelected = false { didSet { needsDisplay = true } }
    var iconOnly = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    init(space: SpaceStyle, shortcut: String) {
        self.space = space
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "\(space.name)  \(shortcut)"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Espace \(space.name)")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(space: SpaceStyle) {
        self.space = space
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private var attributedName: NSAttributedString {
        NSAttributedString(string: space.name, attributes: [
            .font: Theme.sans(12, .semibold),
            .foregroundColor: isSelected ? Theme.onHue(space.hue) : Theme.hueInk(space.hue),
        ])
    }

    override var intrinsicContentSize: NSSize {
        if iconOnly { return NSSize(width: 36, height: 36) }
        return NSSize(width: 36, height: max(64, ceil(attributedName.size().width) + 28))
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor = isSelected ? Theme.hue(space.hue) : Theme.hueSoft(space.hue, 0.12 + 0.08 * Double(hover))
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Theme.radius, yRadius: Theme.radius).fill()

        if iconOnly {
            let tint = isSelected ? Theme.onHue(space.hue) : Theme.hueInk(space.hue)
            let image = NSImage.oreeSymbol(space.icon.symbol, size: 15, weight: .medium) { tint }
            let s = image.size
            image.draw(in: NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2, width: s.width, height: s.height))
            return
        }
        // Vertical label, reading bottom to top.
        let text = attributedName
        let size = text.size()
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: bounds.midX, yBy: bounds.midY)
        t.rotate(byDegrees: 90)
        t.concat()
        text.draw(at: NSPoint(x: -size.width / 2, y: -size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
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
    override func menu(for event: NSEvent) -> NSMenu? { contextMenuProvider?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// One tab in the compact rail: just its favicon, with the title as tooltip.
@MainActor
final class RailTabView: HoverView {
    var onClick: (() -> Void)?
    private let badge = LetterBadgeView(size: 18, cornerRadius: 5)
    private let active: Bool

    init(title: String, host: String, active: Bool, sleeping: Bool) {
        self.active = active
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        badge.configureFavicon(host: host.isEmpty ? title : host, fallbackText: host.isEmpty ? title : host)
        badge.alphaValue = sleeping ? 0.5 : 1
        addSubview(badge)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36), heightAnchor.constraint(equalToConstant: 30),
            badge.centerXAnchor.constraint(equalTo: centerXAnchor), badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = title
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard active || hover > 0.001 else { return }
        (active ? Theme.raised : Theme.hover.scaled(hover)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Theme.radiusSmall + 2, yRadius: Theme.radiusSmall + 2).fill()
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

/// The 52 pt column on the far left: one spine per space, "+" to add one, overview and settings at the bottom.
@MainActor
final class SpaceRailView: NSView {
    var onSelect: ((Int) -> Void)?
    var onRename: ((Int) -> Void)?
    var onNewSpace: (() -> Void)?
    var onOverview: (() -> Void)?
    var onSettings: (() -> Void)?

    private let spines = NSStackView()
    private lazy var spinesTop = spines.topAnchor.constraint(equalTo: topAnchor, constant: CGFloat(OreeTokens.Metrics.toolbarHeight))
    /// Space above the first spine (the title row with the traffic lights; much smaller in full screen).
    func setTopInset(_ value: CGFloat) { spinesTop.constant = value }
    private let addButton = ChromeIconButton(symbol: "plus", label: "Nouvel espace", size: 36, pointSize: 14)
    private let overviewButton = ChromeIconButton(symbol: "square.grid.2x2", label: "Vue d’ensemble des espaces  ⌃↑", size: 36, pointSize: 14)
    private let settingsButton = ChromeIconButton(symbol: "gearshape", label: "Réglages  ⌘,", size: 36, pointSize: 14)
    private var buttons: [SpineButton] = []
    private var compact = false
    private let strip = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        spines.orientation = .vertical
        spines.spacing = 8
        spines.alignment = .centerX
        spines.translatesAutoresizingMaskIntoConstraints = false
        let bottom = NSStackView(views: [overviewButton, settingsButton])
        bottom.orientation = .vertical
        bottom.spacing = 4
        bottom.alignment = .centerX
        bottom.translatesAutoresizingMaskIntoConstraints = false
        strip.orientation = .vertical
        strip.spacing = 2
        strip.alignment = .centerX
        strip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spines)
        addSubview(strip)
        addSubview(bottom)
        NSLayoutConstraint.activate([
            spinesTop,
            spines.centerXAnchor.constraint(equalTo: centerXAnchor),
            strip.topAnchor.constraint(equalTo: spines.bottomAnchor, constant: 14),
            strip.centerXAnchor.constraint(equalTo: centerXAnchor),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            bottom.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        addButton.onClick = { [weak self] in self?.onNewSpace?() }
        overviewButton.onClick = { [weak self] in self?.onOverview?() }
        settingsButton.onClick = { [weak self] in self?.onSettings?() }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Espaces")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(spaces: [SpaceStyle], selected: Int, compact: Bool) {
        self.compact = compact
        spines.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons = spaces.enumerated().map { index, space in
            let spine = SpineButton(space: space, shortcut: "⌃\(index + 1)")
            spine.isSelected = index == selected
            spine.iconOnly = compact
            spine.onClick = { [weak self] in self?.onSelect?(index) }
            spine.contextMenuProvider = { [weak self] in
                let menu = NSMenu()
                menu.addItem(ClosureMenuItem(title: "Modifier l’espace…") { self?.onRename?(index) })
                return menu
            }
            return spine
        }
        buttons.forEach(spines.addArrangedSubview)
        spines.addArrangedSubview(addButton)
    }

    /// Compact mode only: favicons of the current space's tabs.
    func setTabs(_ tabs: [(title: String, host: String, active: Bool, sleeping: Bool, onClick: () -> Void)]) {
        strip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard compact else { return }
        for t in tabs {
            let view = RailTabView(title: t.title, host: t.host, active: t.active, sleeping: t.sleeping)
            view.onClick = t.onClick
            strip.addArrangedSubview(view)
        }
    }

    func select(_ index: Int) {
        for (i, spine) in buttons.enumerated() { spine.isSelected = i == index }
    }
}

// MARK: - Address pill

/// The centered address field of the toolbar: bold domain + muted path. It is a button that opens
/// the command palette (⌘L), like the mockup's closed state.
@MainActor
final class AddressPillView: SurfaceView, NSTextFieldDelegate {
    var onClick: (() -> Void)?
    /// Inline editing callbacks.
    var onTextChange: ((String) -> Void)?
    var onCommit: ((String, _ newTab: Bool) -> Void)?
    var onMove: ((Int) -> Void)?
    var onEndEditing: (() -> Void)?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private let kbd = KbdChip("⌘L")
    private(set) var isEditing = false
    private let hoverLayer = CALayer()
    private var hovered = false {
        didSet { if !isEditing { Motion.transaction(Motion.quick) { hoverLayer.opacity = hovered ? 1 : 0 } } }
    }

    override func layout() {
        super.layout()
        Motion.transaction(0, disableActions: true) {
            hoverLayer.frame = bounds
            hoverLayer.cornerRadius = Theme.radius
            hoverLayer.backgroundColor = Theme.cg(Theme.hover, in: self)
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        hoverLayer.backgroundColor = Theme.cg(Theme.hover, in: self)
    }

    init() {
        super.init(fill: Theme.field, cornerRadius: Theme.radius)
        hoverLayer.opacity = 0
        layer?.addSublayer(hoverLayer)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleNone
        icon.setContentHuggingPriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        label.cell?.usesSingleLineMode = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = Theme.sans(13)
        field.alignment = .left
        field.placeholderString = "Rechercher ou saisir une adresse"
        field.isHidden = true
        field.delegate = self
        field.setAccessibilityLabel("Adresse ou recherche")
        kbd.translatesAutoresizingMaskIntoConstraints = false
        [icon, label, field, kbd].forEach(addSubview)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            kbd.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            kbd.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: kbd.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Adresse ou recherche")
        show(url: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var shownURL: URL?

    /// Re-reads radius and text size.
    func refreshMetrics() { cornerRadius = Theme.radius; show(url: shownURL); field.font = Theme.sans(13) }

    func show(url: URL?) {
        shownURL = url
        let secure = url?.scheme == "https"
        icon.image = .oreeSymbol(isEditing ? "magnifyingglass" : (url == nil ? "magnifyingglass" : (secure ? "lock" : "exclamationmark.triangle")),
                                 size: 12, weight: .medium) { [isEditing] in isEditing ? Theme.accentInk : Theme.muted }
        let font = Theme.sans(13, .regular)
        guard let url, let host = url.host else {
            label.attributedStringValue = NSAttributedString(string: "Rechercher ou saisir une adresse",
                                                             attributes: [.font: font, .foregroundColor: Theme.muted])
            setAccessibilityValue(nil)
            return
        }
        var rest = url.path
        if let query = url.query { rest += "?" + query }
        if rest == "/" { rest = "" }
        let text = NSMutableAttributedString(string: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host,
                                             attributes: [.font: Theme.sans(13, .semibold), .foregroundColor: Theme.text])
        text.append(NSAttributedString(string: rest, attributes: [.font: font, .foregroundColor: Theme.muted]))
        label.attributedStringValue = text
        setAccessibilityValue(url.absoluteString)
    }

    // MARK: Inline editing

    func beginEditing(text: String, selectAll: Bool = true) {
        isEditing = true
        hoverLayer.opacity = 0
        field.stringValue = text
        field.isHidden = false
        label.isHidden = true
        kbd.isHidden = true
        fill = Theme.raised
        border = Theme.accent
        borderWidth = 2
        elevation = .two
        show(url: shownURL)
        window?.makeFirstResponder(field)
        if selectAll { field.currentEditor()?.selectAll(nil) } else { field.currentEditor()?.moveToEndOfLine(nil) }
        onTextChange?(field.stringValue)
    }

    func endEditing() {
        guard isEditing else { return }
        isEditing = false
        field.isHidden = true
        label.isHidden = false
        kbd.isHidden = false
        fill = Theme.field
        border = nil
        borderWidth = 1
        elevation = nil
        show(url: shownURL)
    }

    func controlTextDidChange(_ obj: Notification) { onTextChange?(field.stringValue) }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Return/Escape are handled in doCommandBy; this is the "clicked elsewhere" path.
        if isEditing { onEndEditing?() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): onMove?(1); return true
        case #selector(NSResponder.moveUp(_:)): onMove?(-1); return true
        case #selector(NSResponder.insertNewline(_:)): onCommit?(field.stringValue, false); return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): onCommit?(field.stringValue, true); return true
        case #selector(NSResponder.cancelOperation(_:)): onEndEditing?(); return true
        default: return false
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { if !isEditing { onClick?() } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

// MARK: - Lisière

/// The 3 pt vertical line in the active space color between sidebar and page.
@MainActor
final class LisiereView: NSView {
    var hue: OreeTokens.Hue = .mousse { didSet { needsDisplay = true } }
    override init(frame: NSRect) { super.init(frame: frame); translatesAutoresizingMaskIntoConstraints = false }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        Theme.hue(hue).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 1.5, yRadius: 1.5).fill()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Sidebar rows

/// "Rechercher, aller à…  ⌘K" / "Nouvel onglet  ⌘T" style row: icon, label, key hint, hover wash.
@MainActor
final class SidebarRowView: HoverView {
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var heightConstraint: NSLayoutConstraint!

    func refreshMetrics() { heightConstraint.constant = Theme.rowHeight; label.font = Theme.sans(13); needsDisplay = true }

    init(symbol: String, title: String, shortcut: String?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        icon.image = .oreeSymbol(symbol, size: 13, weight: .regular) { Theme.muted }
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = title
        label.font = Theme.sans(13)
        label.textColor = Theme.muted
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon); addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        heightConstraint = heightAnchor.constraint(equalToConstant: Theme.rowHeight)
        heightConstraint.isActive = true
        if let shortcut {
            let kbd = KbdChip(shortcut)
            addSubview(kbd)
            NSLayoutConstraint.activate([
                kbd.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                kbd.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: kbd.leadingAnchor, constant: -6),
            ])
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard hover > 0.001 else { return }
        Theme.hover.scaled(hover).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Theme.radiusSmall + 2, yRadius: Theme.radiusSmall + 2).fill()
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
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }
}

// MARK: - Toolbar

/// 44 pt bar above the page: ← → ↻, the centered address pill, then the right-hand buttons.
@MainActor
final class ToolbarView: NSView {
    let leftStack = NSStackView()
    let rightStack = NSStackView()
    let pill: AddressPillView
    private var leadingInset: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!

    init(pill: AddressPillView) {
        self.pill = pill
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for stack in [leftStack, rightStack] {
            stack.orientation = .horizontal
            stack.spacing = 2
            stack.alignment = .centerY
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
        }
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)
        leadingInset = leftStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        let center = pill.centerXAnchor.constraint(equalTo: centerXAnchor)
        // Below 500 (NSLayoutPriorityWindowSizeStayPut) so they never force the window wider.
        center.priority = NSLayoutConstraint.Priority(400)
        let width = pill.widthAnchor.constraint(equalToConstant: OreeTokens.Metrics.addressMaxWidth)
        width.priority = NSLayoutConstraint.Priority(400)
        heightConstraint = heightAnchor.constraint(equalToConstant: OreeTokens.Metrics.toolbarHeight)
        NSLayoutConstraint.activate([
            heightConstraint,
            leadingInset,
            leftStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            rightStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            center, width,
            pill.widthAnchor.constraint(lessThanOrEqualToConstant: OreeTokens.Metrics.addressMaxWidth),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 12),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -12),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Room for the traffic lights when the sidebar (which normally hosts them) is hidden.
    func setLeadingInset(_ value: CGFloat) { leadingInset.constant = value }
    func setHeight(_ value: CGFloat) { heightConstraint.constant = value }
}

// MARK: - Spinner ring

/// A 16 pt ring with a quarter arc that spins while a page loads (in the space color).
@MainActor
final class SpinnerRingView: NSView {
    var color: NSColor = Theme.accent { didSet { refreshColors() } }
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        for l in [track, arc] {
            l.fillColor = nil
            l.lineWidth = 2
            l.lineCap = .round
            layer?.addSublayer(l)
        }
        arc.strokeEnd = 0.28
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 16), heightAnchor.constraint(equalToConstant: 16)])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let path = CGPath(ellipseIn: rect, transform: nil)
        track.frame = bounds; arc.frame = bounds
        track.path = path; arc.path = path
        arc.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        arc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        refreshColors()
    }

    private func refreshColors() {
        track.strokeColor = Theme.cg(Theme.line, in: self)
        arc.strokeColor = Theme.cg(color, in: self)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshColors() }

    func setSpinning(_ on: Bool) {
        isHidden = !on
        arc.removeAnimation(forKey: "spin")
        guard on, !Motion.reduced else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 0.8
        spin.repeatCount = .infinity
        arc.add(spin, forKey: "spin")
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Group header

/// "▾ Recherche  3" — click to collapse/expand; the chevron turns −90° when collapsed.
@MainActor
final class GroupHeaderView: HoverView {
    var onToggle: (() -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?
    private let chevron = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    init(name: String, tabCount: Int, collapsed: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        chevron.image = .oreeSymbol("chevron.down", size: 9, weight: .semibold) { Theme.muted }
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.wantsLayer = true
        label.stringValue = name
        label.font = Theme.Typo.label
        label.textColor = Theme.muted
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        count.stringValue = "\(tabCount)"
        count.font = Theme.sans(11.5, .medium)
        count.textColor = Theme.muted
        count.translatesAutoresizingMaskIntoConstraints = false
        [chevron, label, count].forEach(addSubview)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -6),
        ])
        setCollapsed(collapsed)
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel("Groupe \(name)")
        setAccessibilityValue(collapsed ? "replié" : "déplié")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setCollapsed(_ collapsed: Bool) {
        chevron.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        chevron.layer?.transform = collapsed ? CATransform3DMakeRotation(.pi / 2, 0, 0, 1) : CATransform3DIdentity
    }

    override func layout() {
        super.layout()
        // Keep the rotation centered once the chevron has its frame.
        if let layer = chevron.layer, layer.anchorPoint != CGPoint(x: 0.5, y: 0.5) || layer.position != CGPoint(x: chevron.frame.midX, y: chevron.frame.midY) {
            let t = layer.transform
            layer.transform = CATransform3DIdentity
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: chevron.frame.midX, y: chevron.frame.midY)
            layer.transform = t
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hover > 0.001 else { return }
        Theme.hover.scaled(hover).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Theme.radiusSmall, yRadius: Theme.radiusSmall).fill()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onToggle?() }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenuProvider?() }
    override func accessibilityPerformPress() -> Bool { onToggle?(); return true }
}

/// Small non-interactive section label ("Pages libres").
@MainActor
func makeSectionLabel(_ title: String) -> NSView {
    let label = NSTextField(labelWithString: title)
    label.font = Theme.Typo.label
    label.textColor = Theme.muted
    label.translatesAutoresizingMaskIntoConstraints = false
    let row = NSView()
    row.translatesAutoresizingMaskIntoConstraints = false
    row.addSubview(label)
    NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
        label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -3),
        row.heightAnchor.constraint(equalToConstant: 28),
    ])
    return row
}

// MARK: - Floating sidebar edge

/// Thin strip on the left edge (floating mode): hovering it reveals the sidebar.
@MainActor
final class EdgeTriggerView: NSView {
    var onReveal: (() -> Void)?
    var onLeave: (() -> Void)?
    var hue: OreeTokens.Hue = .mousse { didSet { needsDisplay = true } }
    private var hovered = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        toolTip = "Afficher les onglets"
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("Afficher les onglets")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Invisible on purpose: just a hover zone on the left edge (no drawn line).
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; onReveal?() }
    override func mouseExited(with event: NSEvent) { hovered = false; onLeave?() }
    override func mouseDown(with event: NSEvent) { onReveal?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onReveal?(); return true }
}

// MARK: - Address suggestions dropdown

/// The list under the address pill while typing: "Rechercher", "Onglets ouverts", "Historique"…
@MainActor
final class AddressDropdownView: SurfaceView {
    private var items: [PaletteItem] = []
    private var rowViews: [DropdownRow] = []
    private(set) var selectedIndex = 0
    private let stack = NSStackView()
    private var heightLimit: NSLayoutConstraint!

    init() {
        super.init(fill: Theme.raised, cornerRadius: Theme.radiusLarge)
        border = Theme.line
        elevation = .three
        isHidden = true
        stack.orientation = .vertical; stack.alignment = .width; stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        setAccessibilityElement(true); setAccessibilityRole(.list); setAccessibilityLabel("Suggestions")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var onPick: ((PaletteItem) -> Void)?
    var hasSelection: Bool { !items.isEmpty && !isHidden }
    var selectedItem: PaletteItem? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }

    func show(_ sections: [PaletteSection]) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        items = []; rowViews = []; selectedIndex = 0
        for section in sections where !section.items.isEmpty {
            stack.addArrangedSubview(Self.header(section.title))
            for item in section.items {
                let row = DropdownRow(item: item)
                let index = items.count
                row.onClick = { [weak self] in self?.onPick?(item); _ = index }
                row.onHover = { [weak self] in self?.select(index) }
                items.append(item); rowViews.append(row)
                stack.addArrangedSubview(row)
            }
        }
        isHidden = items.isEmpty
        select(0)
    }

    func hide() { isHidden = true; items = []; rowViews = [] }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        select((selectedIndex + delta + items.count) % items.count)
    }

    private func select(_ index: Int) {
        selectedIndex = index
        for (i, row) in rowViews.enumerated() { row.isSelected = i == index }
    }

    private static func header(_ title: String) -> NSView {
        let l = oreeLabel(title.uppercased(), font: Theme.sans(11, .semibold), color: Theme.muted)
        let box = NSView(); box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            l.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
            box.heightAnchor.constraint(equalToConstant: 24),
        ])
        return box
    }
}

@MainActor
private final class DropdownRow: NSView {
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }

    init(item: PaletteItem) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let icon: NSView
        switch item.icon {
        case .site(let host):
            let badge = LetterBadgeView(size: 20, cornerRadius: 5)
            badge.configureFavicon(host: host, fallbackText: host)
            icon = badge
        case .symbol(let name):
            let image = NSImageView(image: .oreeSymbol(name, size: 13, weight: .regular) { Theme.muted })
            image.translatesAutoresizingMaskIntoConstraints = false
            icon = image
        }
        let title = oreeLabel(item.title, font: Theme.sans(13, .medium), color: Theme.text)
        title.lineBreakMode = .byTruncatingTail
        let detail = oreeLabel(item.subtitle ?? "", font: Theme.sans(12), color: Theme.muted)
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(240), for: .horizontal)
        let trailing = oreeLabel(item.trailing ?? "", font: Theme.sans(11.5), color: Theme.muted)
        [icon, title, detail, trailing].forEach { addSubview($0); ($0).translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8),
        ])
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel(item.title + (item.subtitle.map { ", " + $0 } ?? ""))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        Theme.accentSoft.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Theme.radiusSmall + 1, yRadius: Theme.radiusSmall + 1).fill()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

// MARK: - Horizontal tab strip

/// "● Perso ⌄" at the left of the horizontal strip: shows the current space, opens the overview.
@MainActor
final class SpaceChipButton: HoverView {
    var onClick: (() -> Void)?
    private var style = SpaceStyle(name: "", hue: .mousse, icon: .leaf)

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("Changer d’espace")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ style: SpaceStyle) { self.style = style; toolTip = "Espaces  ⌃↑"; invalidateIntrinsicContentSize(); needsDisplay = true }

    private var text: NSAttributedString {
        NSAttributedString(string: style.name, attributes: [.font: Theme.sans(12.5, .semibold), .foregroundColor: Theme.hueInk(style.hue)])
    }
    override var intrinsicContentSize: NSSize { NSSize(width: ceil(text.size().width) + 58, height: 26) }

    override func draw(_ dirtyRect: NSRect) {
        Theme.hueSoft(style.hue, 0.16 + 0.06 * Double(hover)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 13, yRadius: 13).fill()
        let tint = Theme.hueInk(style.hue)
        let icon = NSImage.oreeSymbol(style.icon.symbol, size: 12, weight: .semibold) { tint }
        icon.draw(in: NSRect(x: 10, y: bounds.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
        let t = text
        t.draw(at: NSPoint(x: 28, y: bounds.midY - t.size().height / 2))
        let chevron = NSImage.oreeSymbol("chevron.down", size: 9, weight: .semibold) { tint }
        chevron.draw(in: NSRect(x: bounds.maxX - 20, y: bounds.midY - chevron.size.height / 2, width: chevron.size.width, height: chevron.size.height))
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// 42 pt strip above the toolbar (layout "onglets en haut"): space chip, scrolling tabs, "+".
@MainActor
final class TabStripView: NSView {
    let tabsStack = NSStackView()
    let spaceChip = SpaceChipButton()
    let newTabButton = ChromeIconButton(symbol: "plus", label: "Nouvel onglet  ⌘T")
    /// The room between the space chip and the + button: the tabs share exactly this width, no scrolling.
    private let tabsHost = NSView()
    private lazy var chipLeading = spaceChip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 92)
    /// Room for the traffic lights (none in full screen).
    func setLeadingInset(_ value: CGFloat) { chipLeading.constant = value }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        tabsStack.orientation = .horizontal; tabsStack.spacing = 3; tabsStack.alignment = .centerY
        tabsStack.translatesAutoresizingMaskIntoConstraints = false
        tabsHost.translatesAutoresizingMaskIntoConstraints = false
        tabsHost.wantsLayer = true
        tabsHost.layer?.masksToBounds = false
        tabsHost.addSubview(tabsStack)
        [spaceChip, tabsHost, newTabButton].forEach(addSubview)
        // Optional trailing edge: with an absurd number of tabs the strip overflows instead of breaking layout.
        let trailing = tabsStack.trailingAnchor.constraint(lessThanOrEqualTo: tabsHost.trailingAnchor)
        trailing.priority = .init(600)
        NSLayoutConstraint.activate([
            chipLeading,
            spaceChip.centerYAnchor.constraint(equalTo: centerYAnchor),
            tabsHost.leadingAnchor.constraint(equalTo: spaceChip.trailingAnchor, constant: 8),
            tabsHost.topAnchor.constraint(equalTo: topAnchor), tabsHost.bottomAnchor.constraint(equalTo: bottomAnchor),
            tabsHost.trailingAnchor.constraint(equalTo: newTabButton.leadingAnchor, constant: -4),
            newTabButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            newTabButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            tabsStack.leadingAnchor.constraint(equalTo: tabsHost.leadingAnchor),
            tabsStack.centerYAnchor.constraint(equalTo: centerYAnchor),   // the same centre line as the chip and the + button
            trailing,
        ])
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Onglets")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        fitTabs()
    }

    /// Shares the host's width between the tabs (group chips keep their own width): 190 pt at most, 56 pt at least.
    private func fitTabs() {
        let available = tabsHost.bounds.width
        let items = tabsStack.arrangedSubviews
        let tabs = items.compactMap { $0 as? TabButtonView }
        guard available > 0, !tabs.isEmpty else { return }
        let others = items.filter { !($0 is TabButtonView) }.reduce(CGFloat(0)) { $0 + $1.fittingSize.width }
        let gaps = CGFloat(items.count - 1) * tabsStack.spacing
        let width = max(56, min(190, floor((available - others - gaps) / CGFloat(tabs.count))))
        for tab in tabs { tab.setStripWidth(width) }
    }

    /// Re-share the width after the tab list changed.
    func tabsChanged() { needsLayout = true }

    /// Kept for callers: every tab is always in view now.
    func reveal(_ view: NSView) {}
}

/// Group label in the horizontal strip: a small tinted chip.
@MainActor
func makeStripGroupChip(_ name: String, hue: OreeTokens.Hue) -> NSView {
    let box = SurfaceView(fill: Theme.hueSoft(hue, 0.18), cornerRadius: 9)
    let label = oreeLabel(name, font: Theme.sans(11.5, .semibold), color: Theme.hueInk(hue))
    label.lineBreakMode = .byTruncatingTail
    box.addSubview(label)
    NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
        label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
        label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        box.heightAnchor.constraint(equalToConstant: 20),
    ])
    box.setAccessibilityElement(true); box.setAccessibilityLabel("Groupe \(name)")
    return box
}

// MARK: - Sidebar resize handle and glass

/// Invisible 8 pt strip on the sidebar's right edge: drag to resize, double-click to reset.
@MainActor
final class SidebarResizeHandle: NSView {
    /// Called with the pointer's x in window-content coordinates.
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: ((CGFloat) -> Void)?
    var onReset: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    private var dragging = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "Glisser pour redimensionner · double-clic pour rétablir"
        setAccessibilityElement(true); setAccessibilityRole(.splitter); setAccessibilityLabel("Largeur de la barre latérale")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered || dragging else { return }
        Theme.accent.withAlphaComponent(dragging ? 0.8 : 0.45).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.maxX - 3, y: 0, width: 2, height: bounds.height), xRadius: 1, yRadius: 1).fill()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func x(_ event: NSEvent) -> CGFloat { window?.contentView?.convert(event.locationInWindow, from: nil).x ?? 0 }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onReset?(); return }
        dragging = true
    }
    override func mouseDragged(with event: NSEvent) { if dragging { onDrag?(x(event)) } }
    override func mouseUp(with event: NSEvent) { if dragging { dragging = false; onEnd?(x(event)) } }
}

/// Liquid Glass backdrop for the sidebar when it floats over the page (macOS 26+); a blurred
/// sidebar material on older systems.
@MainActor
enum SidebarGlass {
    static func makeBackground() -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 20
            return glass
        }
        let blur = NSVisualEffectView()
        blur.material = .sidebar
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 20
        blur.layer?.masksToBounds = true
        return blur
    }
}
