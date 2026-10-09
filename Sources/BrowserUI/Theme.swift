import AppKit
import CoreText
import BrowserCore

/// « Orée » theme: turns the pure `OreeTokens` into dynamic colors that follow the
/// window appearance (light / dark / auto), plus fonts, radii and motion.
/// Nothing outside this file should contain a literal color, size or duration.
///
/// Note: `NSColor` resolves per appearance, but a `CGColor` copied onto a layer does
/// not follow later changes — views that paint layers re-apply in
/// `viewDidChangeEffectiveAppearance` using `Theme.cg(_:in:)`.
@MainActor
enum Theme {
    // MARK: Colors

    static func color(_ token: DualColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = token.resolved(dark: dark)
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
        }
    }

    /// Resolve a (possibly dynamic) color for a view's current appearance, for layer use.
    static func cg(_ color: NSColor, in view: NSView) -> CGColor {
        var out = color.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { out = color.cgColor }
        return out
    }

    static let chrome = color(OreeTokens.chrome)
    static let page = color(OreeTokens.page)
    static let raised = color(OreeTokens.raised)
    static let field = color(OreeTokens.field)
    static let text = color(OreeTokens.text)
    static let muted = color(OreeTokens.muted)
    static let line = color(OreeTokens.line)
    static let hover = color(OreeTokens.hover)
    static let press = color(OreeTokens.press)

    /// Accent follows the user's choice; read at call time so changes apply on refresh.
    static var accentHue: OreeTokens.Hue = SettingsStore.shared.accentHue
    static var accent: NSColor { color(accentHue.solid) }
    static var accentInk: NSColor { color(accentHue.ink) }
    static var accentSoft: NSColor { color(accentHue.soft()) }
    static var onAccent: NSColor { color(accentHue.onSolid) }

    static func hue(_ hue: OreeTokens.Hue) -> NSColor { color(hue.solid) }
    static func hueSoft(_ hue: OreeTokens.Hue, _ amount: Double = 0.12) -> NSColor { color(hue.soft(amount)) }
    static func hueInk(_ hue: OreeTokens.Hue) -> NSColor { color(hue.ink) }
    static func onHue(_ hue: OreeTokens.Hue) -> NSColor { color(hue.onSolid) }

    /// Page-side background of the home page / interstitials as CSS-friendly values live in
    /// `StartPage`, which reads `OreeTokens` directly.

    // MARK: Legacy names (kept so existing views keep compiling while they migrate)
    static var canvas: NSColor { chrome }
    static var card: NSColor { page }
    static var surface: NSColor { raised }
    static var border: NSColor { line }
    static var divider: NSColor { line }
    static var sidebarActiveRow: NSColor { raised }
    static var secondaryText: NSColor { muted }
    static var tertiaryText: NSColor { muted }
    static var quietText: NSColor { muted }

    // MARK: Fonts

    /// Registers the bundled Instrument Sans / Serif. Falls back silently to the system fonts.
    static func registerFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static var textOffset: CGFloat = CGFloat(SettingsStore.shared.uiTextOffset)

    /// UI font (Instrument Sans, variable weight).
    static func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let size = size + textOffset
        let base = NSFontDescriptor(fontAttributes: [.family: "Instrument Sans"])
        let desc = base.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]])
        return NSFont(descriptor: desc, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    /// Display font (Instrument Serif, italic) for the home date and big titles.
    static func serifItalic(_ size: CGFloat) -> NSFont {
        NSFont(name: "InstrumentSerif-Italic", size: size)
            ?? NSFontManager.shared.convert(NSFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size), toHaveTrait: .italicFontMask)
    }

    /// The type scale of the design system.
    @MainActor enum Typo {
        static var display: NSFont { Theme.serifItalic(84) }
        static var title: NSFont { Theme.serifItalic(46) }
        static var heading: NSFont { Theme.sans(20, .semibold) }
        static var subheading: NSFont { Theme.sans(15, .semibold) }
        static var body: NSFont { Theme.sans(13) }
        static var label: NSFont { Theme.sans(12, .semibold) }
        static var caption: NSFont { Theme.sans(11.5, .medium) }
    }

    static let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    // MARK: Spacing / radii / density

    enum Space {
        static let xxs: CGFloat = 2, xs: CGFloat = 4, s: CGFloat = 6, m: CGFloat = 8
        static let l: CGFloat = 12, xl: CGFloat = 16, xxl: CGFloat = 24, huge: CGFloat = 32, giant: CGFloat = 48
    }

    static var density: OreeTokens.Density = SettingsStore.shared.density
    static var rowHeight: CGFloat { CGFloat(density.rowHeight) }

    static var radiusBase: Double = SettingsStore.shared.cornerRadius
    static var radiusSmall: CGFloat { CGFloat(OreeTokens.radii(base: radiusBase).sm) }
    static var radius: CGFloat { CGFloat(OreeTokens.radii(base: radiusBase).base) }
    static var radiusLarge: CGFloat { CGFloat(OreeTokens.radii(base: radiusBase).lg) }
    static let pageCornerRadius = CGFloat(OreeTokens.Metrics.pageCornerRadius)
    static let pill: CGFloat = 999

    // MARK: Elevation (no glass, no gradients: a hairline plus a soft shadow)

    enum Elevation {
        case one, two, three
        var params: (opacity: Float, radius: CGFloat, y: CGFloat) {
            switch self { case .one: (0.10, 2, -1); case .two: (0.12, 8, -3); case .three: (0.20, 24, -10) }
        }
    }

    static func apply(_ level: Elevation, to layer: CALayer) {
        let p = level.params
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = p.opacity
        layer.shadowRadius = p.radius
        layer.shadowOffset = CGSize(width: 0, height: p.y)
    }

    // MARK: Appearance mode

    /// Applies light / dark / auto to the whole app (windows, popovers, settings).
    static func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .auto: NSApp.appearance = nil
        }
    }

    /// Posted when any visual preference changed; views re-read their tokens.
    static let didChange = Notification.Name("Theme.didChange")

    // MARK: Badge colors (letter badges for sites without a favicon)

    private static let badgePalette: [OreeTokens.Hue] = [.marine, .mousse, .prune, .ocre, .graphite, .brique]

    static func badgeHue(for text: String) -> OreeTokens.Hue {
        let hash = text.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return badgePalette[abs(hash) % badgePalette.count]
    }

    static func badgeColor(for text: String) -> NSColor { hue(badgeHue(for: text)) }
}

/// Shared animation timing (120 / 180 / 260 ms, cubic-bezier(.2,.8,.2,1)).
/// Collapses to a quick fade when the user asked for less motion.
@MainActor
enum Motion {
    static let quick: TimeInterval = OreeTokens.Motion.fast
    static let standard: TimeInterval = OreeTokens.Motion.base
    static let slow: TimeInterval = OreeTokens.Motion.slow
    nonisolated(unsafe) static let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)

    static var reduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || SettingsStore.shared.calmMotion
    }

    /// Core Animation counterpart of `animate`: design-system duration and curve, shortened to a quick fade
    /// when the user asked for reduced motion.
    static func transaction(_ duration: TimeInterval = standard, disableActions: Bool = false, _ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduced ? min(duration, quick) : duration)
        CATransaction.setAnimationTimingFunction(timing)
        CATransaction.setDisableActions(disableActions)
        body()
        CATransaction.commit()
    }

    static func animate(_ duration: TimeInterval = standard, _ changes: () -> Void, completion: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduced ? min(duration, quick) : duration
            context.timingFunction = timing
            context.allowsImplicitAnimation = !reduced
            changes()
        }, completionHandler: completion.map { done in { MainActor.assumeIsolated { done() } } })
    }
}

/// Public entry point for the app target (Theme itself stays internal to BrowserUI).
@MainActor
public enum ThemeBootstrap {
    public static func start() {
        Theme.registerFonts()
        Theme.applyAppearance(SettingsStore.shared.appearanceMode)
    }
}


extension NSColor {
    /// Same (dynamic) color with its alpha multiplied by `k` — used to fade hover washes in and out.
    func scaled(_ k: CGFloat) -> NSColor {
        let base = self
        return NSColor(name: nil) { appearance in
            var resolved = base
            appearance.performAsCurrentDrawingAppearance { resolved = base.usingColorSpace(.sRGB) ?? base }
            return resolved.withAlphaComponent(resolved.alphaComponent * max(0, min(1, k)))
        }
    }
}

/// A view whose hover state fades in and out (120 ms, design-system curve) instead of snapping.
/// Subclasses draw with `hover` (0...1) and just set `hovered` from mouse enter / exit.
@MainActor
class HoverView: NSView {
    @objc dynamic var hover: CGFloat = 0 { didSet { needsDisplay = true } }

    var hovered = false {
        didSet {
            guard hovered != oldValue else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.reduced ? Motion.quick : Motion.quick
                context.timingFunction = Motion.timing
                context.allowsImplicitAnimation = true
                animator().hover = hovered ? 1 : 0
            }
        }
    }

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "hover" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }
}
