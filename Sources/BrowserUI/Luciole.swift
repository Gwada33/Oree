import AppKit
import BrowserCore

/// Luciole, la mascotte du panneau IA, fidèle à la fiche « mascotte et animations » : sept formes sur une grille de 40 × 40 (halo, ailes, antennes,
/// lanterne, tête, yeux), treize poses, une seule animation en boucle à la fois. Couleurs par jeton : halo accent à 15 %, lanterne accent, tête et
/// antennes texte, ailes surface avec filet texte à 45 %, yeux couleur de page. Avec « réduire les animations », chaque pose reste fixe.
@MainActor
final class LucioleView: NSView {
    private let root = CALayer()
    private let halo = CAShapeLayer(), lantern = CAShapeLayer(), head = CAShapeLayer()
    private let wingLOuter = CALayer(), wingLInner = CAShapeLayer(), wingROuter = CALayer(), wingRInner = CAShapeLayer()
    private let body = CALayer()                       // antennes, pointes, lanterne, tête, yeux : « bd » dans la fiche
    private let antennae = CAShapeLayer(), tipL = CAShapeLayer(), tipR = CAShapeLayer()
    private let eyes = CALayer()                       // « es »
    private let eyeL = CAShapeLayer(), eyeR = CAShapeLayer()
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
        wingLOuter.addSublayer(wingLInner); wingROuter.addSublayer(wingRInner)
        eyes.addSublayer(eyeL); eyes.addSublayer(eyeR)
        for l in [antennae, tipL, tipR, lantern, head, eyes] as [CALayer] { body.addSublayer(l) }
        for l in [halo, wingLOuter, wingROuter, body] as [CALayer] { root.addSublayer(l) }
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size)])
        setAccessibilityElement(false)                   // décor : l'état est dit par le texte à côté
        apply(.idle)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }
    nonisolated override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); recolor() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply(state) }   // les boucles repartent à l'ouverture

    // MARK: Forme (grille 40 × 40, mesures de la fiche)

    private func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil) }

    private func buildShapes() {
        halo.path = circle(20, 26.5, 11)
        lantern.path = circle(20, 26.5, 5.6)
        head.path = circle(20, 17, 8.6)
        wingLInner.path = CGPath(ellipseIn: CGRect(x: 11 - 6, y: 10 - 3.3, width: 12, height: 6.6), transform: nil)
        wingRInner.path = CGPath(ellipseIn: CGRect(x: 29 - 6, y: 10 - 3.3, width: 12, height: 6.6), transform: nil)
        let a = CGMutablePath()
        a.move(to: CGPoint(x: 17.4, y: 10)); a.addQuadCurve(to: CGPoint(x: 13.2, y: 5.4), control: CGPoint(x: 15.8, y: 6.4))
        a.move(to: CGPoint(x: 22.6, y: 10)); a.addQuadCurve(to: CGPoint(x: 26.8, y: 5.4), control: CGPoint(x: 24.2, y: 6.4))
        antennae.path = a
        antennae.fillColor = nil; antennae.lineWidth = 1.25; antennae.lineCap = .round
        tipL.path = circle(13.2, 5.4, 1.3); tipR.path = circle(26.8, 5.4, 1.3)
        eyeL.path = CGPath(roundedRect: CGRect(x: 16.1, y: 14.8, width: 2.5, height: 4.2), cornerWidth: 1.25, cornerHeight: 1.25, transform: nil)
        eyeR.path = CGPath(roundedRect: CGRect(x: 21.4, y: 14.8, width: 2.5, height: 4.2), cornerWidth: 1.25, cornerHeight: 1.25, transform: nil)
        // Tous les calques ont le cadre de la grille (origine en haut à gauche) : les mouvements pivotent autour d'un point de la grille (`pivot`).
        let all: [CALayer] = [halo, lantern, head, wingLOuter, wingLInner, wingROuter, wingRInner, body, antennae, tipL, tipR, eyes, eyeL, eyeR]
        for l in all { l.bounds = CGRect(x: 0, y: 0, width: 40, height: 40); l.anchorPoint = .zero; l.position = .zero }
        // Les ailes sont inclinées de ±30° autour de leur centre, comme dans la fiche.
        wingLOuter.transform = pivot(11, 10, angle: -30 * .pi / 180)
        wingROuter.transform = pivot(29, 10, angle: 30 * .pi / 180)
        recolor()
    }

    private func recolor() {
        func cg(_ c: NSColor) -> CGColor { Theme.cg(c, in: self) }
        halo.fillColor = cg(Theme.accent)
        lantern.fillColor = cg(Theme.accent)
        head.fillColor = cg(Theme.text)
        for w in [wingLInner, wingRInner] { w.fillColor = cg(Theme.raised); w.strokeColor = cg(Theme.text.withAlphaComponent(0.45)); w.lineWidth = 1 }
        antennae.strokeColor = cg(Theme.text)
        for t in [tipL, tipR] { t.fillColor = cg(Theme.text) }
        for e in [eyeL, eyeR] { e.fillColor = cg(Theme.page) }
    }

    /// Échelle, rotation et décalage autour du point (x ; y) de la grille.
    private func pivot(_ x: CGFloat, _ y: CGFloat, scaleX: CGFloat = 1, scaleY: CGFloat = 1, angle: CGFloat = 0, dx: CGFloat = 0, dy: CGFloat = 0) -> CATransform3D {
        var t = CATransform3DMakeTranslation(x + dx, y + dy, 0)
        t = CATransform3DRotate(t, angle, 0, 0, 1)
        t = CATransform3DScale(t, scaleX, scaleY, 1)
        return CATransform3DTranslate(t, -x, -y, 0)
    }

    // MARK: Poses (les règles de la fiche, une par état)

    private static let bodyPivot = CGPoint(x: 20, y: 23.7)      // origine 50 % 70 % du corps
    private static let eyesPivot = CGPoint(x: 20, y: 16.9)
    private static let haloPivot = CGPoint(x: 20, y: 26.5)

    func apply(_ new: LucioleState) {
        state = new
        for l in [halo, lantern, body, eyes, eyeL, eyeR, wingLInner, wingRInner] as [CALayer] { l.removeAllAnimations() }
        let bp = Self.bodyPivot, ep = Self.eyesPivot, hp = Self.haloPivot
        var haloOpacity: Float = 0.15, haloScale: CGFloat = 1, lanternOpacity: Float = 1
        var bodyT = CATransform3DIdentity, eyesT = CATransform3DIdentity
        var eyeScaleY: CGFloat = 1
        switch new {
        case .idle: break
        case .read: break
        case .think: eyesT = pivot(ep.x, ep.y, dx: 1, dy: -1.4); haloOpacity = 0.22
        case .write: eyesT = pivot(ep.x, ep.y, dy: 0.9); haloOpacity = 0.24
        case .act: haloOpacity = 0.24
        case .wait: haloOpacity = 0.28; haloScale = 1.2
        case .ask: bodyT = pivot(bp.x, bp.y, angle: -11 * .pi / 180); eyesT = pivot(ep.x, ep.y, dx: -0.8)
        case .happy: eyeScaleY = 0.42; haloOpacity = 0.26
        case .sleep: eyeScaleY = 0.14; lanternOpacity = 0.22; haloOpacity = 0
        case .load: eyeScaleY = 0.14; haloOpacity = 0
        case .wake: break
        case .err: lanternOpacity = 0.4; bodyT = pivot(bp.x, bp.y, angle: 8 * .pi / 180, dy: 1); eyesT = pivot(ep.x, ep.y, dy: 1.3); haloOpacity = 0.06
        case .off: lanternOpacity = 0.18; haloOpacity = 0; eyesT = pivot(ep.x, ep.y, dx: -1.7)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        halo.opacity = haloOpacity; halo.transform = pivot(hp.x, hp.y, scaleX: haloScale, scaleY: haloScale)
        lantern.opacity = lanternOpacity
        body.transform = bodyT
        eyes.transform = eyesT
        eyeL.transform = pivot(17.35, 16.9, scaleY: eyeScaleY); eyeR.transform = pivot(22.65, 16.9, scaleY: eyeScaleY)
        CATransaction.commit()
        guard window != nil, !Motion.reduced else { return }       // pose fixe si le mouvement est réduit

        func loop(_ layer: CALayer, _ key: String, _ path: String, values: [Any], times: [Double], duration: Double, linear: Bool = false) {
            let k = CAKeyframeAnimation(keyPath: path)
            k.values = values; k.keyTimes = times.map { NSNumber(value: $0) }
            k.duration = duration; k.repeatCount = .infinity
            k.timingFunctions = (0..<max(values.count - 1, 1)).map { _ in linear ? CAMediaTimingFunction(name: .linear) : CAMediaTimingFunction(name: .easeInEaseOut) }
            layer.add(k, forKey: key)
        }
        func t(_ x: CGFloat, _ y: CGFloat, _ build: (CGFloat, CGFloat) -> CATransform3D) -> NSValue { NSValue(caTransform3D: build(x, y)) }
        func blink(_ duration: Double) {
            for (eye, cx) in [(eyeL, CGFloat(17.35)), (eyeR, CGFloat(22.65))] {
                loop(eye, "blink", "transform", values: [1, 1, 0.1, 1, 1].map { NSValue(caTransform3D: pivot(cx, 16.9, scaleY: $0)) }, times: [0, 0.93, 0.96, 0.99, 1], duration: duration)
            }
        }
        func breathe(_ duration: Double) {
            loop(halo, "breathe", "transform", values: [1, 1.15, 1].map { NSValue(caTransform3D: pivot(hp.x, hp.y, scaleX: $0, scaleY: $0)) }, times: [0, 0.5, 1], duration: duration)
            loop(halo, "breatheOpacity", "opacity", values: [0.13, 0.22, 0.13], times: [0, 0.5, 1], duration: duration)
        }
        func bob(_ duration: Double, from: CGFloat = 0, to: CGFloat = -0.9) {
            loop(body, "bob", "transform", values: [from, to, from].map { NSValue(caTransform3D: pivot(bp.x, bp.y, dy: $0)) }, times: [0, 0.5, 1], duration: duration)
        }
        switch new {
        case .idle: breathe(2.6); blink(4.2)
        case .read:
            loop(eyes, "scan", "transform", values: [-1.5, 1.5, -1.5].map { NSValue(caTransform3D: pivot(ep.x, ep.y, dx: $0)) }, times: [0, 0.5, 1], duration: 1.6)
            blink(4.2)
        case .think: loop(lantern, "pulse", "opacity", values: [1, 0.42, 1], times: [0, 0.5, 1], duration: 0.9)
        case .write: bob(0.6)
        case .act:
            bob(1, from: -0.8, to: -2.6)
            let origin = (left: CGPoint(x: 17, y: 10.66), right: CGPoint(x: 5 + 24, y: 10.66))      // 100 % 60 % de l'aile gauche, 0 % 60 % de la droite (avant l'inclinaison)
            loop(wingLInner, "flap", "transform", values: [0, -24, 0].map { NSValue(caTransform3D: pivot(origin.left.x, origin.left.y, angle: $0 * .pi / 180)) }, times: [0, 0.5, 1], duration: 0.16, linear: true)
            loop(wingRInner, "flap", "transform", values: [0, 24, 0].map { NSValue(caTransform3D: pivot(origin.right.x, origin.right.y, angle: $0 * .pi / 180)) }, times: [0, 0.5, 1], duration: 0.16, linear: true)
        case .wait: blink(5)
        case .ask: breathe(1.6); blink(3)
        case .happy:
            loop(body, "hop", "transform", values: [0, -4.5, 0, -1.6, 0, 0].map { NSValue(caTransform3D: pivot(bp.x, bp.y, dy: $0)) }, times: [0, 0.1, 0.19, 0.27, 0.34, 1], duration: 2.6)
        case .sleep: bob(3.2)
        case .load:
            loop(lantern, "fill", "opacity", values: [0.2, 1, 1], times: [0, 0.9, 1], duration: 4, linear: true)
            bob(3.2)
        case .wake:
            for (eye, cx) in [(eyeL, CGFloat(17.35)), (eyeR, CGFloat(22.65))] {
                loop(eye, "wake", "transform", values: [0.14, 0.14, 1, 1].map { NSValue(caTransform3D: pivot(cx, 16.9, scaleY: $0)) }, times: [0, 0.2, 0.45, 1], duration: 2.8)
            }
            loop(lantern, "on", "opacity", values: [0.22, 0.22, 1, 1], times: [0, 0.15, 0.45, 1], duration: 2.8)
            loop(halo, "pop", "opacity", values: [0, 0, 0.3, 0.15, 0.15], times: [0, 0.22, 0.38, 0.5, 1], duration: 2.8)
            loop(halo, "popScale", "transform", values: [0.6, 0.6, 1.25, 1, 1].map { NSValue(caTransform3D: pivot(hp.x, hp.y, scaleX: $0, scaleY: $0)) }, times: [0, 0.22, 0.38, 0.5, 1], duration: 2.8)
        case .err, .off: break
        }
    }
}
