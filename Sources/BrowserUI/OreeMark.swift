import AppKit
import BrowserCore

/// The « Clairière » mark: a disc (radius 24 on a 64×64 grid) filled with vertical bars, clipped by
/// the circle, with a horizontal gradient. Drawn as vectors — no image. Below 48 pt the simplified
/// 4-bar version is used so the bars stay legible.
@MainActor
final class OreeMark: NSView {
    /// Bars as (x0, x1) on the 64-grid; every bar spans y 7…57.
    private static let fullBars: [(CGFloat, CGFloat)] = [
        (8, 15), (16.2, 21.52), (22.98, 27.03), (28.81, 31.88), (34.06, 36.4), (39.05, 40.83), (44.07, 45.42), (49.37, 50.4), (55.22, 56),
    ]
    private static let simpleBars: [(CGFloat, CGFloat)] = [(8, 21), (25.93, 33.47), (40.11, 44.49), (53.46, 56)]

    /// Default gradient: moss → ochre (light) / pale moss → pale ochre (dark).
    static let defaultStart = Theme.color(DualColor(0x2F7354, 0x7FCBA2))
    static let defaultEnd = Theme.color(DualColor(0xD9A441, 0xE2B455))

    var startColor: NSColor { didSet { needsDisplay = true } }
    var endColor: NSColor { didSet { needsDisplay = true } }
    /// Opacity of the gradient's end (1 = opaque; a single-colour mark fades to 0.55, a space mark to 0.45).
    var endOpacity: CGFloat { didSet { needsDisplay = true } }
    /// nil = automatic (simplified under 48 pt).
    var simplified: Bool? { didSet { needsDisplay = true } }
    private let side: CGFloat

    init(size: CGFloat, start: NSColor = OreeMark.defaultStart, end: NSColor = OreeMark.defaultEnd,
         endOpacity: CGFloat = 1, simplified: Bool? = nil) {
        side = size
        startColor = start; endColor = end; self.endOpacity = endOpacity; self.simplified = simplified
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Same hue at both ends, fading to 45 % — the mark in the colour of the active space.
    convenience init(size: CGFloat, hue: OreeTokens.Hue, simplified: Bool? = nil) {
        self.init(size: size, start: Theme.hue(hue), end: Theme.hue(hue), endOpacity: 0.45, simplified: simplified)
    }

    func setSpace(hue: OreeTokens.Hue) {
        startColor = Theme.hue(hue); endColor = Theme.hue(hue); endOpacity = 0.45
    }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }
    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let extent = min(bounds.width, bounds.height)
        guard extent > 0 else { return }
        var start = CGColor.black, end = CGColor.black
        effectiveAppearance.performAsCurrentDrawingAppearance {
            start = startColor.cgColor
            end = (endColor.usingColorSpace(.sRGB) ?? endColor).withAlphaComponent(
                (endColor.usingColorSpace(.sRGB)?.alphaComponent ?? 1) * endOpacity).cgColor
        }
        let bars = (simplified ?? (extent < 48)) ? Self.simpleBars : Self.fullBars

        ctx.saveGState()
        // viewBox "6 6 52 52", centred in the view.
        let scale = extent / 52
        ctx.translateBy(x: (bounds.width - extent) / 2, y: (bounds.height - extent) / 2)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -6, y: -6)
        ctx.addEllipse(in: CGRect(x: 8, y: 8, width: 48, height: 48))
        ctx.clip()
        ctx.addRects(bars.map { CGRect(x: $0.0, y: 7, width: $0.1 - $0.0, height: 50) })
        ctx.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [start, end] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 8, y: 0), end: CGPoint(x: 56, y: 0),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }
}

/// « À propos d’Orée »: the mark, the name and the version.
@MainActor
final class AboutPanel: NSPanel {
    static let shared = AboutPanel()

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 250),
                   styleMask: [.titled, .closable], backing: .buffered, defer: true)
        title = "À propos d’Orée"
        isReleasedWhenClosed = false
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let build = (info?["CFBundleVersion"] as? String) ?? "1"

        let mark = OreeMark(size: 72)
        let name = oreeLabel("Orée", font: Theme.sans(26, .bold), color: Theme.text)
        name.alignment = .center
        let ver = oreeLabel("Version \(version) (\(build))", font: Theme.sans(12), color: Theme.muted)
        ver.alignment = .center
        let tag = oreeLabel("Un navigateur qui dort quand vous ne le regardez pas.\nAucune télémétrie.", font: Theme.sans(12), color: Theme.muted, lines: 3)
        tag.alignment = .center

        let stack = NSStackView(views: [mark, name, ver, tag])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 8
        stack.setCustomSpacing(14, after: mark)
        stack.setCustomSpacing(14, after: ver)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        contentView = content
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -40),
        ])
        center()
    }

    func present() { makeKeyAndOrderFront(nil) }
}
