import AppKit
import BrowserCore

/// An icon that never takes the click: pressing exactly on it must still press the button behind it.
final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A favorite in the 4-column grid: the site badge on a soft tile.
/// Right-click opens its menu (open in a new tab, copy link, remove).
@MainActor
class PinTileView: HoverView {
    var onClick: (() -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?
    var dashed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 34).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.radius, yRadius: Theme.radius)
        Theme.hover.setFill()
        path.fill()
        if hover > 0.001 { Theme.hover.scaled(hover).setFill(); path.fill() }
        if dashed {
            Theme.line.setStroke()
            path.setLineDash([3, 3], count: 2, phase: 0)
            path.stroke()
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
    override func menu(for event: NSEvent) -> NSMenu? { contextMenuProvider?() }
    override func mouseDown(with event: NSEvent) {
        if !Motion.reduced {
            let pop = CAKeyframeAnimation(keyPath: "opacity")
            pop.values = [1, 0.55, 1]
            pop.duration = Motion.quick
            pop.timingFunction = Motion.timing
            layer?.add(pop, forKey: "press")
        }
        onClick?()
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }
}

@MainActor
final class FavoriteTileView: PinTileView {
    private let badge = LetterBadgeView(size: 20, cornerRadius: 6)

    init(url: String, title: String) {
        super.init(frame: .zero)
        let host = URL(string: url)?.host ?? url
        badge.configureFavicon(host: host, fallbackText: host)
        addSubview(badge)
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = title.isEmpty ? host : title
        setAccessibilityLabel(title.isEmpty ? host : title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// The last cell of the favorites grid: adds the page you're on.
@MainActor
final class AddFavoriteTileView: PinTileView {
    init() {
        super.init(frame: .zero)
        dashed = true
        let plus = PassthroughImageView(image: .oreeSymbol("plus", size: 13, weight: .medium) { Theme.muted })
        plus.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plus)
        NSLayoutConstraint.activate([
            plus.centerXAnchor.constraint(equalTo: centerXAnchor),
            plus.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = "Ajouter la page en cours aux favoris"
        setAccessibilityLabel("Ajouter la page en cours aux favoris")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// A 2 pt line along the top of the page that fills as the page loads, in the active space's color.
@MainActor
final class LoadingBarView: NSView {
    private let fill = CALayer()
    private var hideWork: DispatchWorkItem?
    /// Color of the bar (the active space hue).
    var color: NSColor = Theme.accent

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        fill.opacity = 0
        layer?.addSublayer(fill)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var progress: CGFloat = 0

    /// `progress` is 0...1; the bar fades out shortly after reaching 1 or when loading stops.
    func update(progress newValue: Double, isLoading: Bool) {
        hideWork?.cancel()
        fill.backgroundColor = Theme.cg(color, in: self)
        if isLoading {
            progress = max(CGFloat(newValue), 0.06)   // always show a visible stub at the start
            Motion.transaction(Motion.standard) {
                fill.opacity = 1
                applyFrame()
            }
        } else {
            Motion.transaction(Motion.standard) {
                progress = 1
                applyFrame()
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                Motion.transaction(Motion.slow) { self.fill.opacity = 0 }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    private func applyFrame() {
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyFrame()
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        fill.backgroundColor = Theme.cg(color, in: self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never steals clicks from the page
}
