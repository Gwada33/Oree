import AppKit
import BrowserCore

// Small draw-based controls in the Orée style (they follow light/dark by drawing with dynamic colors).

/// A row of exclusive options in a rounded track; the selected one is raised.
@MainActor
final class SegmentedPills: NSView {
    private(set) var options: [String]
    private(set) var selected: Int
    var onChange: ((Int) -> Void)?
    private var hoveredIndex: Int?

    init(options: [String], selected: Int, onChange: ((Int) -> Void)? = nil) {
        self.options = options; self.selected = selected; self.onChange = onChange
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func select(_ index: Int) { selected = index; needsDisplay = true }

    private func rect(_ i: Int) -> NSRect {
        let w = bounds.width / CGFloat(max(options.count, 1))
        return NSRect(x: w * CGFloat(i), y: 0, width: w, height: bounds.height).insetBy(dx: 2, dy: 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.field.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Theme.radiusSmall + 2, yRadius: Theme.radiusSmall + 2).fill()
        for (i, title) in options.enumerated() {
            let r = rect(i)
            if i == selected {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow(); shadow.shadowBlurRadius = 2; shadow.shadowOffset = NSSize(width: 0, height: -1)
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.15); shadow.set()
                Theme.raised.setFill()
                NSBezierPath(roundedRect: r, xRadius: Theme.radiusSmall, yRadius: Theme.radiusSmall).fill()
                NSGraphicsContext.restoreGraphicsState()
            } else if i == hoveredIndex {
                Theme.hover.setFill()
                NSBezierPath(roundedRect: r, xRadius: Theme.radiusSmall, yRadius: Theme.radiusSmall).fill()
            }
            let text = NSAttributedString(string: title, attributes: [
                .font: Theme.sans(12.5, i == selected ? .semibold : .medium),
                .foregroundColor: i == selected ? Theme.text : Theme.muted,
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
        }
    }

    private func index(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return options.indices.first { rect($0).insetBy(dx: -2, dy: -2).contains(p) }
    }
    override func mouseDown(with event: NSEvent) {
        guard let i = index(at: event) else { return }
        selected = i; needsDisplay = true; onChange?(i)
    }
    override func mouseMoved(with event: NSEvent) { hoveredIndex = index(at: event); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hoveredIndex = nil; needsDisplay = true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// iOS-style switch drawn in the accent color.
@MainActor
final class SwitchToggle: NSView {
    private(set) var isOn: Bool
    var onChange: ((Bool) -> Void)?

    init(isOn: Bool, label: String, onChange: ((Bool) -> Void)? = nil) {
        self.isOn = isOn; self.onChange = onChange
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 38), heightAnchor.constraint(equalToConstant: 22)])
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(label)
        setAccessibilityValue(isOn ? "activé" : "désactivé")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(_ on: Bool) { isOn = on; needsDisplay = true; setAccessibilityValue(on ? "activé" : "désactivé") }

    override func draw(_ dirtyRect: NSRect) {
        (isOn ? Theme.accent : Theme.press).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11).fill()
        let knob = NSRect(x: isOn ? bounds.maxX - 20 : 2, y: 2, width: 18, height: 18)
        (isOn ? Theme.onAccent : Theme.raised).setFill()
        NSBezierPath(ovalIn: knob).fill()
    }
    override func mouseDown(with event: NSEvent) { set(!isOn); onChange?(isOn) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { set(!isOn); onChange?(isOn); return true }
}

/// A row of six color dots; the selected one gets a ring.
@MainActor
final class SwatchRow: NSView {
    private let hues = OreeTokens.Hue.allCases
    private(set) var selected: OreeTokens.Hue
    var onChange: ((OreeTokens.Hue) -> Void)?

    init(selected: OreeTokens.Hue, onChange: ((OreeTokens.Hue) -> Void)? = nil) {
        self.selected = selected; self.onChange = onChange
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([heightAnchor.constraint(equalToConstant: 32)])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func select(_ hue: OreeTokens.Hue) { selected = hue; needsDisplay = true }
    private func center(_ i: Int) -> NSPoint { NSPoint(x: 16 + CGFloat(i) * 40, y: bounds.midY) }

    override func draw(_ dirtyRect: NSRect) {
        for (i, hue) in hues.enumerated() {
            let c = center(i)
            if hue == selected {
                Theme.hue(hue).setStroke()
                let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28)); ring.lineWidth = 2; ring.stroke()
            }
            Theme.hue(hue).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 10, y: c.y - 10, width: 20, height: 20)).fill()
        }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = hues.indices.first(where: { hypot(center($0).x - p.x, center($0).y - p.y) < 16 }) else { return }
        selected = hues[i]; needsDisplay = true; onChange?(selected)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Text button in the style of the mockup: `.btn` primary / secondary / ghost.
@MainActor
final class TextButton: HoverView {
    enum Style { case primary, secondary, ghost }
    var onClick: (() -> Void)?
    private let style: Style
    private let title: String

    init(_ title: String, style: Style = .secondary, onClick: (() -> Void)? = nil) {
        self.title = title; self.style = style; self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var label: NSAttributedString {
        let color: NSColor = style == .primary ? Theme.onAccent : Theme.text
        return NSAttributedString(string: title, attributes: [.font: Theme.sans(12.5, .semibold), .foregroundColor: color])
    }
    override var intrinsicContentSize: NSSize { NSSize(width: ceil(label.size().width) + 28, height: 30) }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: Theme.radiusSmall + 2, yRadius: Theme.radiusSmall + 2)
        switch style {
        case .primary:
            Theme.accent.setFill(); path.fill()
            if hover > 0.001 { NSColor.black.withAlphaComponent(0.14 * hover).setFill(); path.fill() }
        case .secondary:
            Theme.field.setFill(); path.fill()
            if hover > 0.001 { Theme.hover.scaled(hover).setFill(); path.fill() }
        case .ghost:
            if hover > 0.001 { Theme.hover.scaled(hover).setFill(); path.fill() }
        }
        let size = label.size()
        label.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
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

// MARK: - Layout helpers

@MainActor
func oreeLabel(_ text: String, font: NSFont, color: NSColor, lines: Int = 1) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = font
    field.textColor = color
    field.maximumNumberOfLines = lines
    field.alignment = .left
    field.translatesAutoresizingMaskIntoConstraints = false
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
}

/// "Title / description        [control]" row used by the drawer and settings.
@MainActor
func oreeSettingRow(title: String, detail: String? = nil, control: NSView) -> NSView {
    let titleLabel = oreeLabel(title, font: Theme.sans(13, .semibold), color: Theme.text)
    var labels: [NSView] = [titleLabel]
    if let detail { labels.append(oreeLabel(detail, font: Theme.sans(12), color: Theme.muted, lines: 3)) }
    let text = NSStackView(views: labels)
    text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
    text.translatesAutoresizingMaskIntoConstraints = false
    let row = NSStackView(views: [text, control])
    row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12; row.distribution = .fill
    row.translatesAutoresizingMaskIntoConstraints = false
    text.setContentHuggingPriority(.defaultLow, for: .horizontal)
    control.setContentHuggingPriority(.required, for: .horizontal)
    return row
}
