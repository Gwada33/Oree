import AppKit
import BrowserCore
import OreeAIClient

/// Luciole, la mascotte du panneau IA : une petite luciole dessinée en sept formes vectorielles sur une grille de 40 × 40
/// (halo, ailes, antennes, lanterne, tête, yeux). Pas de dégradé ni de flou. Les poses ne changent que des opacités, des
/// décalages et des rotations, en boucle ; avec « réduire les animations », la pose reste fixe.
@MainActor
final class LucioleView: NSView {
    private let root = CALayer()
    private let halo = CAShapeLayer(), lantern = CAShapeLayer(), head = CAShapeLayer()
    private let wingL = CAShapeLayer(), wingR = CAShapeLayer()
    private let antennae = CAShapeLayer(), tipL = CAShapeLayer(), tipR = CAShapeLayer()
    private let eyeL = CAShapeLayer(), eyeR = CAShapeLayer()
    private let eyes = CALayer()
    private(set) var state: LucioleState = .idle
    private let side: CGFloat

    init(size: CGFloat) {
        side = size
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.addSublayer(root)
        root.isGeometryFlipped = true                    // la grille est en y vers le bas, comme le dessin d'origine
        root.bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
        root.anchorPoint = .zero
        root.setAffineTransform(CGAffineTransform(scaleX: size / 40, y: size / 40))
        buildShapes()
        for l in [halo, wingL, wingR, antennae, tipL, tipR, lantern, head] as [CALayer] { root.addSublayer(l) }
        root.addSublayer(eyes)
        eyes.addSublayer(eyeL); eyes.addSublayer(eyeR)
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size)])
        setAccessibilityElement(false)                   // décor : l'état est dit par le texte à côté
        apply(.idle, animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); recolor(); apply(state, animated: false) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply(state, animated: false) }   // les boucles repartent à l'ouverture

    // MARK: Forme

    private func buildShapes() {
        func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil) }
        func wing(_ cx: CGFloat, _ angle: CGFloat) -> CGPath {
            // Une ellipse de 12 × 6,6 centrée en (cx, 10), tournée de `angle` autour de son centre.
            var t = CGAffineTransform(translationX: cx, y: 10).rotated(by: angle * .pi / 180)
            return CGPath(ellipseIn: CGRect(x: -6, y: -3.3, width: 12, height: 6.6), transform: &t)
        }
        halo.path = circle(20, 26.5, 11)
        lantern.path = circle(20, 26.5, 5.6)
        head.path = circle(20, 17, 8.6)
        wingL.path = wing(11, -30); wingR.path = wing(29, 30)
        let a = CGMutablePath()
        a.move(to: CGPoint(x: 17.4, y: 10)); a.addQuadCurve(to: CGPoint(x: 13.2, y: 5.4), control: CGPoint(x: 15.8, y: 6.4))
        a.move(to: CGPoint(x: 22.6, y: 10)); a.addQuadCurve(to: CGPoint(x: 26.8, y: 5.4), control: CGPoint(x: 24.2, y: 6.4))
        antennae.path = a
        antennae.fillColor = nil; antennae.lineWidth = 1.25; antennae.lineCap = .round
        tipL.path = circle(13.2, 5.4, 1.3); tipR.path = circle(26.8, 5.4, 1.3)
        eyeL.path = CGPath(roundedRect: CGRect(x: 16.1, y: 14.8, width: 2.5, height: 4.2), cornerWidth: 1.25, cornerHeight: 1.25, transform: nil)
        eyeR.path = CGPath(roundedRect: CGRect(x: 21.4, y: 14.8, width: 2.5, height: 4.2), cornerWidth: 1.25, cornerHeight: 1.25, transform: nil)
        // Toutes les formes partagent le cadre de la grille (origine en haut à gauche) : les animations pivotent autour d'un point
        // de la grille grâce à `pivot`, jamais en déplaçant l'ancre des calques.
        for l in [halo, lantern, head, wingL, wingR, antennae, tipL, tipR, eyeL, eyeR, eyes] as [CALayer] { l.bounds = CGRect(x: 0, y: 0, width: 40, height: 40); l.anchorPoint = .zero; l.position = .zero }
        recolor()
    }

    private func recolor() {
        func cg(_ c: NSColor) -> CGColor { Theme.cg(c, in: self) }
        halo.fillColor = cg(Theme.accent.withAlphaComponent(0.22))
        lantern.fillColor = cg(Theme.accent)
        head.fillColor = cg(Theme.text)
        for w in [wingL, wingR] { w.fillColor = cg(Theme.muted.withAlphaComponent(0.28)); w.strokeColor = cg(Theme.muted.withAlphaComponent(0.55)); w.lineWidth = 0.8 }
        antennae.strokeColor = cg(Theme.text)
        for t in [tipL, tipR] { t.fillColor = cg(Theme.accent) }
        for e in [eyeL, eyeR] { e.fillColor = cg(Theme.page) }
    }

    /// Une transformation (échelle puis rotation) autour du point (x ; y) de la grille.
    private func pivot(_ x: CGFloat, _ y: CGFloat, scale: CGFloat = 1, angle: CGFloat = 0) -> CATransform3D {
        var t = CATransform3DMakeTranslation(x, y, 0)
        t = CATransform3DRotate(t, angle, 0, 0, 1)
        t = CATransform3DScale(t, scale, scale, 1)
        return CATransform3DTranslate(t, -x, -y, 0)
    }

    // MARK: Poses

    /// Ce que chaque pose change : (halo, vitesse de la lanterne, ailes, balayage des yeux, rebond, clignement, yeux fermés).
    private struct Pose {
        var halo: Float = 1, pulse: Double = 3.2, flap: Double = 0, scan: Double = 0, bob: Double = 0, blink = true, shut = false, lantern: Float = 1
    }
    private func pose(for state: LucioleState) -> Pose {
        switch state {
        case .idle: Pose()
        case .read: Pose(scan: 1.6)
        case .think: Pose(pulse: 1.1, bob: 1.8)
        case .write: Pose(pulse: 1.6, flap: 0.5)
        case .act: Pose(pulse: 0.9, flap: 0.28, bob: 1.2)
        case .wait: Pose(pulse: 2.4, blink: false)
        case .ask: Pose(pulse: 1.4, bob: 2.4)
        case .happy: Pose(pulse: 1.0, flap: 0.4, bob: 0.8)
        case .sleep: Pose(halo: 0.2, pulse: 0, blink: false, shut: true, lantern: 0.45)
        case .load: Pose(pulse: 0.8, bob: 1.4)
        case .wake: Pose(pulse: 1.2, flap: 0.6)
        case .err: Pose(halo: 0.35, pulse: 0, blink: false, lantern: 0.6)
        case .off: Pose(halo: 0, pulse: 0, blink: false, shut: true, lantern: 0.25)
        }
    }

    func apply(_ new: LucioleState, animated: Bool = true) {   // `animated` : réservé au fondu entre deux poses (non fait)
        state = new
        for l in [halo, lantern, wingL, wingR, eyes, eyeL, eyeR] as [CALayer] { l.removeAllAnimations() }
        let p = pose(for: new)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        halo.opacity = p.halo
        lantern.opacity = p.lantern
        // Yeux fermés : écrasés sur leur milieu (y = 16,9), pas sur l'origine de la grille.
        eyes.transform = p.shut ? CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(0, 16.9, 0), 1, 0.15, 1), 0, -16.9, 0) : CATransform3DIdentity
        CATransaction.commit()
        guard window != nil, !Motion.reduced else { return }        // pose fixe si le mouvement est réduit
        func loop(_ key: String, on layer: CALayer, _ animation: CAAnimation) {
            animation.repeatCount = .infinity; animation.autoreverses = true
            animation.timingFunction = Motion.timing
            layer.add(animation, forKey: key)
        }
        if p.pulse > 0 {
            let b = CABasicAnimation(keyPath: "transform"); b.fromValue = pivot(20, 26.5, scale: 0.94); b.toValue = pivot(20, 26.5, scale: 1.08); b.duration = p.pulse / 2
            loop("pulse", on: lantern, b)
            let h = CABasicAnimation(keyPath: "opacity"); h.fromValue = p.halo * 0.55; h.toValue = p.halo; h.duration = p.pulse / 2
            loop("halo", on: halo, h)
        }
        if p.flap > 0 {
            for (wing, sign) in [(wingL, -1.0), (wingR, 1.0)] {
                let cx: CGFloat = wing === wingL ? 11 : 29
                let r = CABasicAnimation(keyPath: "transform"); r.fromValue = pivot(cx, 10); r.toValue = pivot(cx, 10, angle: CGFloat(sign) * 24 * .pi / 180); r.duration = p.flap
                loop("flap", on: wing, r)
            }
        }
        if p.scan > 0 {
            let s = CABasicAnimation(keyPath: "transform.translation.x"); s.fromValue = -1.4; s.toValue = 1.4; s.duration = p.scan
            loop("scan", on: eyes, s)
        }
        if p.bob > 0 {
            let s = CABasicAnimation(keyPath: "transform.translation.y"); s.fromValue = 0; s.toValue = -1.2; s.duration = p.bob / 2
            loop("bob", on: eyes, s)
        }
        if p.blink {
            let k = CAKeyframeAnimation(keyPath: "opacity"); k.values = [1, 1, 0, 1, 1]; k.keyTimes = [0, 0.9, 0.94, 0.98, 1]
            k.duration = 4.6; k.repeatCount = .infinity
            eyeL.add(k, forKey: "blink"); eyeR.add(k, forKey: "blink")
        } else { eyeL.removeAllAnimations(); eyeR.removeAllAnimations() }
    }
}
