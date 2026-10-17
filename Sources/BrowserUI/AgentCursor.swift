import AppKit
import WebKit
import BrowserCore

/// Ce que l'exécuteur d'actions demande à la « présence » de Luciole dans la page : aller vers l'élément, appuyer, repartir.
@MainActor
protocol AgentPresence: AnyObject {
    func reveal(rect: CGRect, in web: WKWebView, kind: PresenceKind) async
    func press() async
    func hold(_ pose: LucioleState)
    func follow(_ pose: LucioleState)
    func settle(failed: Bool)
    func hideNow()
}

enum PresenceKind {
    case click, type, select
    var verb: String { switch self { case .click: "Luciole clique…"; case .type: "Luciole écrit…"; case .select: "Luciole choisit…" } }
    var pose: LucioleState { self == .type ? .write : .act }
}

/// Luciole qui se déplace dans la page. Pendant une tâche, elle reste en vue dans un coin de la page et sa pose suit ce qui se passe vraiment (elle réfléchit, lit,
/// attend le fournisseur…) ; pour un geste, elle vole jusqu'à l'élément visé, un cadre d'accent l'entoure un instant, elle « appuie » (une onde part de l'élément),
/// puis le cadre s'efface et elle regagne son coin. Quand la tâche est finie, elle repart vers le panneau. Dessiné par Orée dans une couche au-dessus de la WKWebView — jamais injecté dans le DOM du site —
/// et sans prise sur la souris. Avec « réduire les animations », elle apparaît à sa place sans voler.
@MainActor
final class AgentCursor: NSView, AgentPresence {
    private let mascot = LucioleView(size: 34)
    private let ring = SurfaceView(fill: Theme.accentSoft, cornerRadius: 6)
    private let tagBox = SurfaceView(fill: Theme.raised, cornerRadius: Theme.pill)
    private let tagLabel = NSTextField(labelWithString: "")
    private var target: CGPoint = .zero
    private var placed = false
    private var atElement = false        // elle est près d'un élément (geste en cours, question ou validation) : elle n'en bouge pas d'elle-même
    /// L'élément visé (pixels CSS de la fenêtre d'affichage) : la couche de Luciole dans la page en fait un pas du chemin ou le trou de la validation.
    var onReveal: ((CGRect, WKWebView) -> Void)?
    /// Une seule Luciole à l'écran : d'où elle part et où elle revient (le centre de la mascotte de la couche, de la capsule ou de la barre d'outils), en coordonnées de cette vue.
    var homeProvider: (() -> CGPoint?)?
    /// Vrai quand elle est au travail dans la page : la couche cache alors sa propre mascotte, pour qu'il n'y ait jamais deux Luciole.
    var onPresence: ((Bool) -> Void)?
    private var generation = 0            // chaque nouvelle tâche (ou arrêt) invalide un départ programmé

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        isHidden = true
        ring.border = Theme.accent; ring.borderWidth = 2
        ring.translatesAutoresizingMaskIntoConstraints = true
        mascot.translatesAutoresizingMaskIntoConstraints = true
        mascot.frame = NSRect(x: 0, y: 0, width: 34, height: 34)
        tagBox.translatesAutoresizingMaskIntoConstraints = true
        tagBox.elevation = .two
        tagLabel.font = Theme.sans(11.5, .semibold); tagLabel.textColor = Theme.text
        tagLabel.translatesAutoresizingMaskIntoConstraints = false
        tagBox.addSubview(tagLabel)
        NSLayoutConstraint.activate([tagLabel.leadingAnchor.constraint(equalTo: tagBox.leadingAnchor, constant: 9), tagLabel.centerYAnchor.constraint(equalTo: tagBox.centerYAnchor)])
        for v in [ring, tagBox, mascot] as [NSView] { addSubview(v) }
        ring.alphaValue = 0; tagBox.alphaValue = 0
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attach(to host: NSView) {
        guard superview !== host else { return }
        host.addSubview(self)
        NSLayoutConstraint.activate([topAnchor.constraint(equalTo: host.topAnchor), bottomAnchor.constraint(equalTo: host.bottomAnchor),
                                     leadingAnchor.constraint(equalTo: host.leadingAnchor), trailingAnchor.constraint(equalTo: host.trailingAnchor)])
    }

    /// Son coin de repos : en haut à droite de la page, du côté du panneau.
    private var dock: CGPoint {
        if let home = homeProvider?() { return CGPoint(x: home.x - 17, y: home.y - 17) }
        return CGPoint(x: max(bounds.maxX - 34 - 18, 4), y: 14)
    }

    /// La pose suit un événement réel de la tâche. Elle apparaît dans son coin à la première (une tâche qui démarre) et n'en bouge plus tant qu'aucun geste ne l'appelle.
    func follow(_ pose: LucioleState) {
        guard superview != nil, pose != .idle else { return }
        generation += 1                                  // une tâche qui reprend annule un départ programmé
        layoutSubtreeIfNeeded()
        mascot.apply(pose)
        if isHidden || !placed {
            isHidden = false
            ring.alphaValue = 0; tagBox.alphaValue = 0
            mascot.frame.origin = CGPoint(x: bounds.maxX + 6, y: dock.y); mascot.alphaValue = 0
            placed = true; atElement = false
            if Motion.reduced { mascot.frame.origin = dock; mascot.alphaValue = 1; return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35; context.timingFunction = Motion.timing; context.allowsImplicitAnimation = true
                self.mascot.animator().frame.origin = self.dock
                self.mascot.animator().alphaValue = 1
            }
        }
    }

    /// Le geste est fini : le cadre et l'étiquette s'effacent, la luciole regagne son coin (sauf si une autre action a commencé entre-temps).
    private func release(after delay: Double) {
        let mine = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == mine, !self.isHidden else { return }
                self.atElement = false
                if Motion.reduced { self.ring.alphaValue = 0; self.tagBox.alphaValue = 0; self.mascot.frame.origin = self.dock; return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.4; context.timingFunction = Motion.timing; context.allowsImplicitAnimation = true
                    self.ring.animator().alphaValue = 0
                    self.tagBox.animator().alphaValue = 0
                    self.mascot.animator().frame.origin = self.dock
                }
            }
        }
    }

    /// Une durée de pause qui ne bloque pas le fil principal.
    private func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    /// Le rectangle de l'élément (pixels CSS de la fenêtre de la page) dans les coordonnées de la couche.
    private func convert(_ rect: CGRect, in web: WKWebView) -> CGRect {
        let zoom = max(web.pageZoom, 0.1)
        let local = NSRect(x: rect.minX * zoom, y: web.isFlipped ? rect.minY * zoom : web.bounds.height - (rect.maxY * zoom), width: rect.width * zoom, height: rect.height * zoom)
        return self.convert(local, from: web)
    }

    func reveal(rect: CGRect, in web: WKWebView, kind: PresenceKind) async {
        onReveal?(rect, web)
        generation += 1
        layoutSubtreeIfNeeded()
        let box = convert(rect, in: web)
        guard box.width > 0, box.height > 0 else { return }
        let wasHidden = isHidden
        isHidden = false
        if wasHidden { onPresence?(true) }
        atElement = true
        target = CGPoint(x: box.midX, y: box.midY)
        tagLabel.stringValue = kind.verb
        mascot.apply(kind.pose)
        let tagSize = NSSize(width: ceil(tagLabel.intrinsicContentSize.width) + 18, height: 22)
        // La luciole se pose au-dessus et à droite du centre de l'élément (la « lanterne » touche l'élément, la page reste lisible).
        var home = CGPoint(x: min(box.midX + 6, bounds.maxX - 40 - tagSize.width), y: max(box.minY - 38, 4))
        home.x = max(home.x, 4)
        let tagFrame = NSRect(x: home.x + 36, y: home.y + 6, width: tagSize.width, height: tagSize.height)
        let ringFrame = box.insetBy(dx: -3, dy: -3)
        if !placed {
            if homeProvider?() != nil { mascot.frame.origin = dock; mascot.alphaValue = 1 }                           // elle part de là où elle était (capsule, passage, barre d'outils)
            else { mascot.frame.origin = CGPoint(x: bounds.maxX + 6, y: home.y); mascot.alphaValue = 0 }              // sans couche : elle arrive du panneau, à droite
        }
        ring.frame = ringFrame
        tagBox.frame = tagFrame
        placed = true
        if Motion.reduced {
            mascot.frame.origin = home; mascot.alphaValue = 1; ring.alphaValue = 1; tagBox.alphaValue = 1
            release(after: 1.4)
            await pause(0.15)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.5
                context.timingFunction = Motion.timing
                context.allowsImplicitAnimation = true
                self.mascot.animator().frame.origin = home
                self.mascot.animator().alphaValue = 1
                self.tagBox.animator().frame = tagFrame
                self.tagBox.animator().alphaValue = 1
                self.ring.animator().frame = ringFrame
                self.ring.animator().alphaValue = 1
            }, completionHandler: { MainActor.assumeIsolated { continuation.resume() } })
        }
        release(after: 1.5)                                       // le cadre ne reste pas posé là : il s'efface après le geste
        await pause(0.12)
    }

    /// « Appuie » : un petit rebond de la luciole et une onde d'accent qui part du point visé ; le clic réel suit 0,15 s plus tard.
    func press() async {
        guard !isHidden else { return }
        if Motion.reduced { await pause(0.1); return }
        let size: CGFloat = 36
        let wave = CAShapeLayer()
        wave.path = CGPath(ellipseIn: CGRect(x: -size / 2, y: -size / 2, width: size, height: size), transform: nil)
        wave.position = target
        wave.fillColor = Theme.cg(Theme.accent.withAlphaComponent(0.28), in: self)
        wave.opacity = 0
        layer?.addSublayer(wave)
        let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 0.25; grow.toValue = 1.7
        let fade = CAKeyframeAnimation(keyPath: "opacity"); fade.values = [0.9, 0]; fade.keyTimes = [0, 1]
        let group = CAAnimationGroup(); group.animations = [grow, fade]; group.duration = Motion.slow + 0.1; group.timingFunction = Motion.timing
        wave.add(group, forKey: "wave")
        // Rebond de la luciole : s'écrase puis revient (120 ms).
        if let host = mascot.layer {
            let squash = CAKeyframeAnimation(keyPath: "transform.scale"); squash.values = [1, 0.84, 1]; squash.keyTimes = [0, 0.45, 1]; squash.duration = Motion.quick
            host.add(squash, forKey: "press")
        }
        await pause(0.15)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { wave.removeFromSuperlayer() }
    }

    /// Elle reste près de l'élément tant qu'une question ou une validation attend, avec la pose qui va avec.
    func hold(_ pose: LucioleState) {
        guard !isHidden else { return }
        mascot.apply(pose)
        if pose == .wait, atElement { generation += 1 }                       // une validation attend : elle reste près du bouton concerné, cadre compris
        if pose == .ask {                                                     // une question s'adresse à la personne : le cadre n'a plus d'objet, Luciole regagne son coin
            generation += 1; atElement = false
            if Motion.reduced { ring.alphaValue = 0; tagBox.alphaValue = 0; mascot.frame.origin = dock; return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35; context.timingFunction = Motion.timing; context.allowsImplicitAnimation = true
                self.ring.animator().alphaValue = 0; self.tagBox.animator().alphaValue = 0; self.mascot.animator().frame.origin = self.dock
            }
        }
    }

    /// Fin de tâche : le cadre s'efface et la luciole repart vers le panneau.
    func settle(failed: Bool = false) {
        guard !isHidden else { return }
        generation += 1
        let mine = generation
        mascot.apply(failed ? .err : .happy)
        let leave = { [weak self] in
            guard let self else { return }
            self.ring.alphaValue = 0; self.tagBox.alphaValue = 0
            if self.homeProvider?() != nil { self.mascot.animator().frame.origin = self.dock }                  // elle revient où elle était : la couche reprend sa mascotte
            else { self.mascot.animator().frame.origin = CGPoint(x: self.bounds.maxX + 6, y: self.mascot.frame.minY); self.mascot.animator().alphaValue = 0 }
        }
        if Motion.reduced { hideNow(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == mine else { return }          // une autre tâche a commencé entre-temps : on ne touche à rien
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.4; context.timingFunction = Motion.timing; context.allowsImplicitAnimation = true
                    leave()
                }, completionHandler: { MainActor.assumeIsolated { if self.generation == mine { self.hideNow() } } })
            }
        }
    }

    /// Dev : où est Luciole (pour les essais).
    var report: String { isHidden ? "hidden" : "at=\(Int(mascot.frame.minX)),\(Int(mascot.frame.minY)) target=\(Int(target.x)),\(Int(target.y)) pose=\(mascot.state.rawValue) ring=\(ring.alphaValue > 0.5 ? "on" : "off") atElement=\(atElement)" }

    /// Arrêt immédiat (Stop, fermeture du panneau) : tout disparaît tout de suite.
    func hideNow() {
        generation += 1
        let wasShown = !isHidden
        isHidden = true; placed = false; atElement = false
        ring.alphaValue = 0; tagBox.alphaValue = 0; mascot.alphaValue = 0
        if wasShown { onPresence?(false) }
    }
}
