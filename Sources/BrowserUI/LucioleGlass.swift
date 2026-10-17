import AppKit
import QuartzCore
import BrowserCore

/// Le « verre de lanterne » : la matière réservée à Luciole (le reste d'Orée reste « pierre, papier, encre »).
/// macOS 26 et plus : `NSGlassEffectView`. Avant : un flou de fenêtre avec un reflet clair en haut, un filet intérieur blanc et une ombre.
/// « Dense » : nettement plus opaque (carte de validation, pastille d'action : leur lisibilité prime). « Réduire la transparence » : surface opaque et ombre, sans flou.
@MainActor
class LucioleGlass: NSView {
    /// Là où l'on pose le contenu.
    let content = NSView()
    private(set) var radius: CGFloat
    let dense: Bool
    private let solid: Bool

    init(radius: CGFloat, dense: Bool = false) {
        self.radius = radius; self.dense = dense
        solid = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = true
        wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false
        build()
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func pin(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }

    private func build() {
        if solid {
            let surface = SurfaceView(fill: Theme.raised, cornerRadius: radius)
            surface.elevation = .three; surface.border = Theme.hover; surface.autoresizingMask = []
            pin(surface); pin(content)
            return
        }
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.style = .regular
            if dense { glass.tintColor = Theme.raised.withAlphaComponent(0.55) }
            glass.contentView = content
            pin(glass)
            shadow(opacity: 0.45)
            return
        }
        let blur = NSVisualEffectView()
        blur.material = .hudWindow; blur.blendingMode = .withinWindow; blur.state = .active
        blur.wantsLayer = true; blur.layer?.cornerRadius = radius; blur.layer?.masksToBounds = true
        pin(blur)
        let highlight = CAGradientLayer()                                  // reflet clair en haut : blanc 0,75 → 0 sur la moitié de la hauteur
        highlight.colors = [NSColor.white.withAlphaComponent(0.75).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        highlight.startPoint = CGPoint(x: 0.5, y: 1); highlight.endPoint = CGPoint(x: 0.5, y: 0.5)
        highlight.cornerRadius = radius; highlight.name = "highlight"
        blur.layer?.addSublayer(highlight)
        if dense { let veil = NSView(); veil.wantsLayer = true; veil.layer?.backgroundColor = Theme.raised.withAlphaComponent(0.8).cgColor; pin(veil) }
        pin(content)
        layer?.borderWidth = 1; layer?.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor; layer?.cornerRadius = radius
        shadow(opacity: 0.45)
    }

    private func shadow(opacity: Float) {
        guard let layer else { return }
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor; layer.shadowOpacity = opacity * 0.5; layer.shadowRadius = 30; layer.shadowOffset = CGSize(width: 0, height: -26)
    }

    override func layout() {
        super.layout()
        for sub in subviews { if let g = sub.layer?.sublayers?.first(where: { $0.name == "highlight" }) { g.frame = sub.bounds } }
        if radius > bounds.height / 2 { radius = bounds.height / 2 }
    }

    // MARK: Apparition et disparition

    /// Échelle 0,86 → 1, opacité 0 → 1, 500 ms avec un léger rebond. (Le flou 6 → 0 de la fiche n'est pas fait : AppKit ne propose pas de flou animable sur une vue.)
    func appear(delay: TimeInterval = 0) {
        isHidden = false
        guard let layer, !Motion.reduced else { alphaValue = 1; return }
        alphaValue = 1
        let spring = CASpringAnimation(keyPath: "transform"); spring.damping = 14; spring.stiffness = 220; spring.mass = 1; spring.initialVelocity = 0
        spring.fromValue = NSValue(caTransform3D: scaleAboutCenter(0.86)); spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.duration = 0.5; spring.beginTime = CACurrentMediaTime() + delay; spring.fillMode = .backwards
        layer.add(spring, forKey: "appear")
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.35
        fade.beginTime = CACurrentMediaTime() + delay; fade.fillMode = .backwards
        layer.add(fade, forKey: "appearFade")
    }

    /// 180 ms, sans rebond.
    func disappear(completion: (() -> Void)? = nil) {
        guard !isHidden else { completion?(); return }
        if Motion.reduced { isHidden = true; completion?(); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.isHidden = true; self?.alphaValue = 1; completion?() })
    }

    /// Une échelle autour du centre, quel que soit le point d'ancrage du calque : M = T((C − A)(1 − s)) · S(s).
    private func scaleAboutCenter(_ s: CGFloat) -> CATransform3D {
        guard let layer else { return CATransform3DIdentity }
        let a = CGPoint(x: layer.anchorPoint.x * bounds.width, y: layer.anchorPoint.y * bounds.height)
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        return CATransform3DScale(CATransform3DMakeTranslation((c.x - a.x) * (1 - s), (c.y - a.y) * (1 - s), 0), s, s, 1)
    }
}

/// Une pastille de verre qui se clique (suggestion, geste de l'éventail).
@MainActor
final class LucioleGlassButton: LucioleGlass {
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var hoverArea: NSTrackingArea?

    init(title: String, symbol: String?, height: CGFloat = LucioleGeometry.pillHeight, font: NSFont = Theme.sans(14, .medium), keyHint: String? = nil) {
        super.init(radius: height / 2)
        label.stringValue = title; label.font = font; label.textColor = Theme.text; label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        var lead = content.leadingAnchor
        if let symbol {
            icon.image = NSImage.oreeSymbol(symbol, size: 13, weight: .regular) { Theme.accent }
            content.addSubview(icon)
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14), icon.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                                         icon.widthAnchor.constraint(equalToConstant: 15), icon.heightAnchor.constraint(equalToConstant: 15)])
            lead = icon.trailingAnchor
        }
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: lead, constant: symbol == nil ? 16 : 8), label.centerYAnchor.constraint(equalTo: content.centerYAnchor)])
        if let keyHint {
            let hint = NSTextField(labelWithString: keyHint); hint.font = Theme.sans(11, .semibold); hint.textColor = Theme.muted; hint.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(hint)
            NSLayoutConstraint.activate([hint.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8), hint.centerYAnchor.constraint(equalTo: content.centerYAnchor)])
        }
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setTitle(_ title: String) { label.stringValue = title; setAccessibilityLabel(title) }

    /// La largeur dont la pastille a besoin (icône, texte, marges), pour la poser sans la couper.
    var idealWidth: CGFloat { ceil(label.intrinsicContentSize.width) + (icon.image == nil ? 32 : 52) + (label.superview?.subviews.contains { $0 !== label && $0 !== icon && $0 is NSTextField } == true ? 28 : 0) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { NSCursor.pointingHand.push(); animateHover(true) }
    override func mouseExited(with event: NSEvent) { NSCursor.pop(); animateHover(false) }
    private func animateHover(_ on: Bool) {
        guard !Motion.reduced, let layer else { return }
        let a = CABasicAnimation(keyPath: "transform.scale"); a.toValue = on ? 1.04 : 1; a.duration = 0.12; a.fillMode = .forwards; a.isRemovedOnCompletion = false
        layer.add(a, forKey: "hover")
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
