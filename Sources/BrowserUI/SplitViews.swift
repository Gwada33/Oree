import AppKit
import BrowserCore

/// Header above one side of the split screen: favicon, title, domain, "show alone" and "close side".
/// The focused side gets an accent bar on top.
@MainActor
final class SplitPaneHeader: NSView {
    var onSolo: (() -> Void)?
    var onClose: (() -> Void)?
    var onFocus: (() -> Void)?
    private let badge = LetterBadgeView(size: 16, cornerRadius: 4)
    private let title = NSTextField(labelWithString: "")
    private let domain = NSTextField(labelWithString: "")
    private let solo = ChromeIconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Afficher seule cette page", size: 24, pointSize: 11)
    private let close = ChromeIconButton(symbol: "xmark", label: "Fermer ce côté", size: 24, pointSize: 11)
    var isFocused = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        title.font = Theme.sans(12.5, .semibold); title.textColor = Theme.text; title.lineBreakMode = .byTruncatingTail
        domain.font = Theme.sans(12); domain.textColor = Theme.muted; domain.lineBreakMode = .byTruncatingTail
        for v in [title, domain] as [NSTextField] { v.translatesAutoresizingMaskIntoConstraints = false }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        domain.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(240), for: .horizontal)
        [badge, title, domain, solo, close].forEach(addSubview)
        solo.onClick = { [weak self] in self?.onSolo?() }
        close.onClick = { [weak self] in self?.onClose?() }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            domain.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            domain.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            solo.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -2),
            solo.centerYAnchor.constraint(equalTo: centerYAnchor),
            domain.trailingAnchor.constraint(lessThanOrEqualTo: solo.leadingAnchor, constant: -8),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title text: String, host: String) {
        title.stringValue = text
        domain.stringValue = host
        badge.configureFavicon(host: host.isEmpty ? text : host, fallbackText: host.isEmpty ? text : host)
        setAccessibilityLabel("Côté : \(text)")
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.setFill(); bounds.fill()
        Theme.line.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        if isFocused { Theme.accent.setFill(); NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2).fill() }
    }
    override func mouseDown(with event: NSEvent) { onFocus?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The hinge between the two sides: a grab handle you can drag, and (on hover) ⅓ ½ ⅔ + swap chips.
@MainActor
final class SplitHingeView: NSView {
    var onRatio: ((CGFloat, Bool) -> Void)?      // (ratio, isFinal)
    var onSwap: (() -> Void)?
    var ratio: CGFloat = 0.5 { didSet { needsDisplay = true } }
    private var hovered = false { didSet { chipsStack.isHidden = !hovered; needsDisplay = true } }
    private var dragging = false
    private let chipsStack = NSStackView()
    private var chips: [(ratio: CGFloat, view: NSView)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        chipsStack.orientation = .vertical; chipsStack.spacing = 2; chipsStack.alignment = .centerX
        chipsStack.translatesAutoresizingMaskIntoConstraints = false
        chipsStack.wantsLayer = true
        chipsStack.isHidden = true
        for (r, label) in [(CGFloat(1) / 3, "⅓"), (0.5, "½"), (CGFloat(2) / 3, "⅔")] {
            let b = TextButton(label, style: .ghost) { [weak self] in self?.onRatio?(r, true) }
            b.widthAnchor.constraint(equalToConstant: 34).isActive = true
            b.setAccessibilityLabel("Répartition \(label)")
            chips.append((r, b)); chipsStack.addArrangedSubview(b)
        }
        let swap = ChromeIconButton(symbol: "arrow.left.arrow.right", label: "Échanger les côtés", size: 34, pointSize: 12)
        swap.onClick = { [weak self] in self?.onSwap?() }
        chipsStack.addArrangedSubview(swap)
        addSubview(chipsStack)
        NSLayoutConstraint.activate([
            chipsStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            chipsStack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 60),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Séparateur d’écran partagé")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let grab = NSRect(x: bounds.midX - 2, y: bounds.midY - 22, width: 4, height: 44)
        (hovered || dragging ? Theme.accent : Theme.press).setFill()
        NSBezierPath(roundedRect: grab, xRadius: 2, yRadius: 2).fill()
        if hovered {
            let card = chipsStack.frame.insetBy(dx: -4, dy: -4)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowBlurRadius = 8; shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.2); shadow.set()
            Theme.raised.setFill()
            NSBezierPath(roundedRect: card, xRadius: Theme.radius, yRadius: Theme.radius).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        let core = NSRect(x: bounds.midX - 8, y: 0, width: 16, height: bounds.height)
        if core.contains(p) { return super.hitTest(point) ?? self }
        return hovered && chipsStack.frame.insetBy(dx: -4, dy: -4).contains(p) ? super.hitTest(point) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { if !dragging { hovered = false } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { dragging = true; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) {
        guard dragging, let host = superview, host.bounds.width > 0 else { return }
        let x = host.convert(event.locationInWindow, from: nil).x
        onRatio?(min(max(x / host.bounds.width, 0.25), 0.75), false)
    }
    override func mouseUp(with event: NSEvent) {
        dragging = false; needsDisplay = true
        if let host = superview, host.bounds.width > 0 {
            let x = host.convert(event.locationInWindow, from: nil).x
            onRatio?(min(max(x / host.bounds.width, 0.25), 0.75), true)
        }
    }
}
