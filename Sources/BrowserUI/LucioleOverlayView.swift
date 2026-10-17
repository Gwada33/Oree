import AppKit
import QuartzCore
import BrowserCore

/// Ce que la couche affiche, d'après l'état de `AIPanelController` (le cerveau ne change pas : seule la présentation change).
struct LucioleOverlayModel {
    var stage: LucioleStage
    var pose: LucioleState
    var placeholder: String
    var composerEnabled: Bool
    var running: Bool
    var suggestions: [(symbol: String, label: String, fill: String, web: Bool)]
    var answer: String
    var sources: [String]
    var note: String
    var hasConversation: Bool
    var contextShared: Bool
    var contextLocked: Bool
    var protectedLine: String?
    // Décision (validation ou question) : la carte est construite par Orée ; `decisionRect` est l'élément concerné, en coordonnées de la couche.
    var confirm: ConfirmRequest?
    var confirmArmed = true
    var question: String?
    var decisionRect: CGRect?
    // Action sur la page : titre de la tâche, étape en cours, plafond, libellés des étapes ; le chemin et l'étape en cours (coordonnées de la couche).
    var actionTitle: String?
    var actionStep = 0
    var actionTotal = 15
    var actionLines: [String] = []
    var path: [(step: Int, rect: CGRect)] = []
}

/// Luciole qui vit DANS la page : une couche native transparente posée au-dessus de la WKWebView de l'onglet actif. Elle ne laisse passer les clics que sur ses
/// propres éléments (capsule, suggestions, bulle) ; rien n'est injecté dans les sites. Pose actuelle : l'appel (capsule + suggestions) et la réponse (bulle).
@MainActor
final class LucioleOverlayView: NSView, NSTextFieldDelegate {
    var onSubmit: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onClose: (() -> Void)?
    var onToggleShare: (() -> Void)?
    var onOpenSource: ((URL) -> Void)?
    var onOpenPage: ((String) -> Void)?
    var onGesture: ((SelectionPassage.Gesture) -> Void)?
    var onConfirm: ((Bool) -> Void)?
    var onAnswer: ((String?) -> Void)?
    private let decisionCard = LucioleDecisionCard()
    private let actionPill = LucioleGlass(radius: 21, dense: true)
    private let pillDot = NSView(), pillTitle = NSTextField(labelWithString: ""), pillStep = NSTextField(labelWithString: "")
    private let stopButton = LucioleGlassButton(title: "Arrêter", symbol: "stop.fill", height: 30, font: Theme.sans(12.5, .semibold), keyHint: "esc")
    private let traceBubble = LucioleGlass(radius: 20)
    private let traceLabel = NSTextField(wrappingLabelWithString: "")
    private var stepViews: [NSView] = []
    private let pathLine = CAShapeLayer(), pathGlow = CAShapeLayer()
    private var traceOpen = false

    /// Ce que la couche montre : la capsule d'appel, la seule bulle de réponse ancrée à un passage (venue d'un geste), ou l'éventail seul.
    private enum Mode { case capsule, answerOnly }
    private var mode: Mode = .capsule
    private let fanMascot = LucioleView(size: 42)
    private var fan: [LucioleGlassButton] = []
    private var fanGestures: [SelectionPassage.Gesture] = []
    private var fanTip: CGPoint?
    private var keyMonitor: Any?
    private let highlight = CAShapeLayer()
    private let thread = CAShapeLayer(), threadHalo = CAShapeLayer()
    /// Les rectangles du passage (repère de la couche), pour la bulle, le surlignage et le fil ; nil : pas de passage.
    private var anchorRects: [CGRect] = []

    private let capsule = LucioleGlass(radius: 33)
    private let capsuleMascot = LucioleView(size: 54)
    private let aura = NSView()
    private let field = NSTextField()
    private let send = SurfaceView(fill: Theme.accent, cornerRadius: 21)
    private let sendIcon = NSImageView()
    private let shareButton = SurfaceView(fill: nil, cornerRadius: 14)
    private var pills: [LucioleGlassButton] = []
    private var shownSuggestions: [String] = []

    private let bubble = LucioleGlass(radius: 26)
    private let bubbleMascot = LucioleView(size: 22)
    private let bubbleTitle = NSTextField(labelWithString: "Luciole")
    private let bubbleScroll = NSScrollView()
    private let bubbleText = NSTextField(wrappingLabelWithString: "")
    private let sourceRow = NSStackView()
    private let followField = NSTextField()
    private let noteLabel = NSTextField(labelWithString: "")
    private let closeButton = SurfaceView(fill: nil, cornerRadius: 14)
    private let openPageButton = LucioleGlassButton(title: "Ouvrir en page", symbol: "doc.richtext", height: 30, font: Theme.sans(12, .medium))
    private var bubbleHeight: CGFloat = 0
    private var model: LucioleOverlayModel?
    private var mouseMonitor: Any?
    private var presented = false
    private var anchorFrame: NSRect?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        isHidden = true
        buildCapsule(); buildBubble()
        for v in [capsule, bubble] { addSubview(v); v.isHidden = true }
        for l in [threadHalo, thread, highlight] { l.fillColor = nil; layer?.addSublayer(l) }
        highlight.fillColor = Theme.accent.withAlphaComponent(0.28).cgColor
        thread.strokeColor = Theme.accent.cgColor; thread.lineWidth = 2; thread.lineCap = .round
        threadHalo.strokeColor = Theme.accent.withAlphaComponent(0.35).cgColor; threadHalo.lineWidth = 7; threadHalo.lineCap = .round
        fanMascot.isHidden = true; addSubview(fanMascot)
        for l in [pathGlow, pathLine] { l.fillColor = nil; l.lineCap = .round; l.lineDashPattern = [1, 7]; layer?.insertSublayer(l, at: 0) }
        pathLine.strokeColor = Theme.accent.cgColor; pathLine.lineWidth = 3
        pathGlow.strokeColor = Theme.accent.withAlphaComponent(0.35).cgColor; pathGlow.lineWidth = 9
        buildActionPill()
        for v in [decisionCard, actionPill, traceBubble] { addSubview(v); v.isHidden = true }
        decisionCard.onPrimary = { [weak self] text in guard let self else { return }; if self.decisionCard.kind == .question { self.onAnswer?(text) } else { self.onConfirm?(true) } }
        decisionCard.onCancel = { [weak self] in guard let self else { return }; if self.decisionCard.kind == .question { self.onAnswer?(nil) } else { self.onConfirm?(false) } }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Construction

    private func buildCapsule() {
        aura.wantsLayer = true; aura.translatesAutoresizingMaskIntoConstraints = false
        aura.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.45).cgColor; aura.layer?.cornerRadius = 22
        let c = capsule.content
        c.addSubview(aura); c.addSubview(capsuleMascot)
        capsuleMascot.translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = Theme.sans(17, .medium); field.textColor = Theme.text; field.delegate = self
        field.placeholderString = "Demandez à Luciole…"; field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail; field.cell?.usesSingleLineMode = true
        field.setAccessibilityLabel("Demander à Luciole")
        send.elevation = .one; send.translatesAutoresizingMaskIntoConstraints = false
        sendIcon.image = NSImage.oreeSymbol("arrow.up", size: 16, weight: .semibold) { Theme.onAccent }
        sendIcon.translatesAutoresizingMaskIntoConstraints = false; send.addSubview(sendIcon)
        shareButton.translatesAutoresizingMaskIntoConstraints = false
        let eye = NSImageView(image: NSImage.oreeSymbol("eye", size: 14, weight: .regular) { Theme.muted }); eye.translatesAutoresizingMaskIntoConstraints = false
        shareButton.addSubview(eye)
        shareButton.setAccessibilityElement(true); shareButton.setAccessibilityRole(.button); shareButton.setAccessibilityLabel("Partager la page avec Luciole")
        c.addSubview(field); c.addSubview(shareButton); c.addSubview(send)
        NSLayoutConstraint.activate([
            capsuleMascot.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8), capsuleMascot.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            aura.centerXAnchor.constraint(equalTo: capsuleMascot.centerXAnchor), aura.centerYAnchor.constraint(equalTo: capsuleMascot.centerYAnchor),
            aura.widthAnchor.constraint(equalToConstant: 44), aura.heightAnchor.constraint(equalToConstant: 44),
            field.leadingAnchor.constraint(equalTo: capsuleMascot.trailingAnchor, constant: 10), field.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            field.trailingAnchor.constraint(equalTo: shareButton.leadingAnchor, constant: -8),
            shareButton.trailingAnchor.constraint(equalTo: send.leadingAnchor, constant: -6), shareButton.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            shareButton.widthAnchor.constraint(equalToConstant: 28), shareButton.heightAnchor.constraint(equalToConstant: 28),
            eye.centerXAnchor.constraint(equalTo: shareButton.centerXAnchor), eye.centerYAnchor.constraint(equalTo: shareButton.centerYAnchor),
            send.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -12), send.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            send.widthAnchor.constraint(equalToConstant: 42), send.heightAnchor.constraint(equalToConstant: 42),
            sendIcon.centerXAnchor.constraint(equalTo: send.centerXAnchor), sendIcon.centerYAnchor.constraint(equalTo: send.centerYAnchor),
        ])
        let sendClick = NSClickGestureRecognizer(target: self, action: #selector(submit)); send.addGestureRecognizer(sendClick)
        send.setAccessibilityElement(true); send.setAccessibilityRole(.button); send.setAccessibilityLabel("Envoyer")
        let shareClick = NSClickGestureRecognizer(target: self, action: #selector(toggleShare)); shareButton.addGestureRecognizer(shareClick)
        capsule.setAccessibilityElement(false)
    }

    private func buildActionPill() {
        let c = actionPill.content
        pillDot.wantsLayer = true; pillDot.layer?.backgroundColor = Theme.accent.cgColor; pillDot.layer?.cornerRadius = 4
        pillTitle.font = Theme.sans(13.5, .semibold); pillTitle.textColor = Theme.text; pillTitle.lineBreakMode = .byTruncatingTail
        pillStep.font = Theme.sans(12); pillStep.textColor = Theme.muted
        for v in [pillDot, pillTitle, pillStep, stopButton] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(v) }
        NSLayoutConstraint.activate([
            pillDot.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 16), pillDot.centerYAnchor.constraint(equalTo: c.centerYAnchor), pillDot.widthAnchor.constraint(equalToConstant: 8), pillDot.heightAnchor.constraint(equalToConstant: 8),
            pillTitle.leadingAnchor.constraint(equalTo: pillDot.trailingAnchor, constant: 10), pillTitle.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            pillStep.leadingAnchor.constraint(equalTo: pillTitle.trailingAnchor, constant: 10), pillStep.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            stopButton.leadingAnchor.constraint(greaterThanOrEqualTo: pillStep.trailingAnchor, constant: 12), stopButton.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6),
            stopButton.centerYAnchor.constraint(equalTo: c.centerYAnchor), stopButton.widthAnchor.constraint(equalToConstant: 104), stopButton.heightAnchor.constraint(equalToConstant: 30),
        ])
        pillTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stopButton.onClick = { [weak self] in self?.onStop?() }
        actionPill.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(togglePillTrace)))
        actionPill.setAccessibilityElement(true); actionPill.setAccessibilityRole(.button)
        traceLabel.font = Theme.sans(12.5); traceLabel.textColor = Theme.text; traceLabel.translatesAutoresizingMaskIntoConstraints = false
        traceBubble.content.addSubview(traceLabel)
        NSLayoutConstraint.activate([traceLabel.leadingAnchor.constraint(equalTo: traceBubble.content.leadingAnchor, constant: 16), traceLabel.trailingAnchor.constraint(equalTo: traceBubble.content.trailingAnchor, constant: -16),
                                     traceLabel.topAnchor.constraint(equalTo: traceBubble.content.topAnchor, constant: 12), traceLabel.bottomAnchor.constraint(equalTo: traceBubble.content.bottomAnchor, constant: -12)])
        traceBubble.setAccessibilityElement(true); traceBubble.setAccessibilityRole(.list); traceBubble.setAccessibilityLabel("Étapes de Luciole")
    }

    @objc private func togglePillTrace() { traceOpen.toggle(); if !traceOpen { traceBubble.disappear() } else { traceBubble.isHidden = false; traceBubble.appear() }; relayout() }

    private func buildBubble() {
        let c = bubble.content
        bubbleTitle.font = Theme.sans(12, .semibold); bubbleTitle.textColor = Theme.muted
        for v in [bubbleMascot, bubbleTitle, bubbleScroll, sourceRow, followField, noteLabel, closeButton] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(v) }
        let x = NSImageView(image: NSImage.oreeSymbol("xmark", size: 11, weight: .semibold) { Theme.muted }); x.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addSubview(x)
        closeButton.setAccessibilityElement(true); closeButton.setAccessibilityRole(.button); closeButton.setAccessibilityLabel("Fermer Luciole")
        closeButton.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(closeTapped)))
        bubbleText.isSelectable = true; bubbleText.translatesAutoresizingMaskIntoConstraints = true
        bubbleScroll.drawsBackground = false; bubbleScroll.hasVerticalScroller = true; bubbleScroll.autohidesScrollers = true; bubbleScroll.borderType = .noBorder
        bubbleScroll.documentView = FlippedDocument()
        bubbleScroll.documentView?.addSubview(bubbleText)
        sourceRow.orientation = .horizontal; sourceRow.spacing = 6; sourceRow.alignment = .centerY
        followField.placeholderString = "Continuer ici…"; followField.font = Theme.sans(13); followField.isBordered = false; followField.drawsBackground = true
        followField.backgroundColor = Theme.hover; followField.focusRingType = .none; followField.delegate = self; followField.wantsLayer = true
        followField.layer?.cornerRadius = 12; followField.setAccessibilityLabel("Continuer la conversation")
        noteLabel.font = Theme.sans(11); noteLabel.textColor = Theme.muted; noteLabel.lineBreakMode = .byTruncatingTail
        openPageButton.onClick = { [weak self] in if let text = self?.model?.answer { self?.onOpenPage?(text) } }
        NSLayoutConstraint.activate([
            bubbleMascot.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 16), bubbleMascot.topAnchor.constraint(equalTo: c.topAnchor, constant: 14),
            bubbleMascot.widthAnchor.constraint(equalToConstant: 22), bubbleMascot.heightAnchor.constraint(equalToConstant: 22),
            bubbleTitle.leadingAnchor.constraint(equalTo: bubbleMascot.trailingAnchor, constant: 6), bubbleTitle.centerYAnchor.constraint(equalTo: bubbleMascot.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -10), closeButton.centerYAnchor.constraint(equalTo: bubbleMascot.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 28), closeButton.heightAnchor.constraint(equalToConstant: 28),
            x.centerXAnchor.constraint(equalTo: closeButton.centerXAnchor), x.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            bubbleScroll.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 18), bubbleScroll.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -18),
            bubbleScroll.topAnchor.constraint(equalTo: bubbleMascot.bottomAnchor, constant: 8),
            sourceRow.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 18), sourceRow.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -18),
            sourceRow.topAnchor.constraint(equalTo: bubbleScroll.bottomAnchor, constant: 8), sourceRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            followField.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 16), followField.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -16),
            followField.topAnchor.constraint(equalTo: sourceRow.bottomAnchor, constant: 10), followField.heightAnchor.constraint(equalToConstant: 34),
            noteLabel.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 18), noteLabel.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -18),
            noteLabel.topAnchor.constraint(equalTo: followField.bottomAnchor, constant: 8), noteLabel.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -12),
        ])
    }

    private final class FlippedDocument: NSView { override var isFlipped: Bool { true } }

    // MARK: Interaction

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        let interactive: [NSView] = [capsule, bubble, decisionCard, actionPill, traceBubble] + pills + fan
        return interactive.contains { !$0.isHidden && $0.frame.contains(local) } ? super.hitTest(point) : nil     // partout ailleurs : la page reçoit le clic
    }

    @objc private func submit() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, model?.composerEnabled == true else { return }
        field.stringValue = ""
        onSubmit?(text)
    }
    @objc private func toggleShare() { onToggleShare?() }
    @objc private func closeTapped() { onClose?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if control === field { submit() } else if control === followField {
                let text = followField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, model?.composerEnabled == true { followField.stringValue = ""; onSubmit?(text) }
            }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) { onClose?(); return true }
        return false
    }

    /// Échap arrête une tâche en cours (le panneau la garde pour « Arrêter ») ; sinon il renvoie Luciole dormir.
    override func cancelOperation(_ sender: Any?) { if model?.running == true { onStop?() } else { onClose?() } }

    /// Une vue cachée n'est pas mise en page : sa taille reste nulle et les conversions de coordonnées se retrouvent en miroir. On la dispose avant de convertir.
    func prepareGeometry() {
        guard bounds.isEmpty else { return }
        let wasHidden = isHidden
        isHidden = false
        superview?.layoutSubtreeIfNeeded()
        isHidden = wasHidden
    }

    func focusComposer() { window?.makeFirstResponder(mode == .answerOnly ? followField : field) }

    // MARK: Présentation

    /// L'appel : Luciole quitte la barre d'outils (`from`, en coordonnées de fenêtre) et descend dans la capsule.
    func present(from toolbarButton: NSRect?) {
        guard !presented else { return }
        hideFan()
        mode = .capsule
        presented = true; anchorFrame = toolbarButton
        isHidden = false
        layoutSubtreeIfNeeded(); relayout()
        capsule.appear()
        flyMascot(from: toolbarButton)
        startAura()
        installKeyMonitor()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.presented, self.mode == .capsule, self.model?.stage == .call, event.window === self.window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            let inside = ([self.capsule] + self.pills).contains { !$0.isHidden && $0.frame.contains(point) }
            if !inside { DispatchQueue.main.async { self.onClose?() } }          // un clic hors de la capsule la renvoie dormir (le clic atteint aussi la page)
            return event
        }
    }

    func dismiss() {
        guard presented else { return }
        presented = false
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        clearAnchor()
        if fan.isEmpty { removeKeyMonitor() }
        pills.forEach { $0.disappear() }
        bubble.disappear()
        capsule.disappear { [weak self] in
            guard let self, !self.presented else { return }
            self.isHidden = self.fan.isEmpty
            self.pills.forEach { $0.removeFromSuperview() }; self.pills = []; self.shownSuggestions = []
            self.stopAura()
        }
    }

    /// Le vol de la mascotte : position et taille, courbe (0,45 ; 0 ; 0,15 ; 1), 800 ms, légère inclinaison dans le sens du vol. Sans animations : elle apparaît à sa place.
    private func flyMascot(from button: NSRect?) {
        guard !Motion.reduced, let button, let window else { return }
        let from = convert(window.contentView?.convert(button, from: nil) ?? button, from: nil)
        let start = CGPoint(x: from.midX, y: from.midY)
        guard let host = capsuleMascot.layer, let target = capsuleMascot.superview else { return }
        let end = CGPoint(x: capsule.frame.minX + 8 + 27, y: capsule.frame.midY)
        let dx = start.x - end.x, dy = start.y - end.y
        let curve = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.15, 1)
        let move = CABasicAnimation(keyPath: "transform.translation"); move.fromValue = NSValue(size: NSSize(width: dx, height: dy)); move.toValue = NSValue(size: .zero)
        let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = 28.0 / 54.0; scale.toValue = 1
        let tilt = CAKeyframeAnimation(keyPath: "transform.rotation.z"); let lean = CGFloat(max(-0.35, min(0.35, -dx / 900)))
        tilt.values = [0, lean, 0]; tilt.keyTimes = [0, 0.4, 1]
        let group = CAAnimationGroup(); group.animations = [move, scale, tilt]; group.duration = 0.8; group.timingFunction = curve
        host.add(group, forKey: "flight")
        _ = target
    }

    private func startAura() {
        guard !Motion.reduced, let layer = aura.layer else { return }
        let breathe = CABasicAnimation(keyPath: "opacity"); breathe.fromValue = 0.25; breathe.toValue = 0.7; breathe.duration = 2.2; breathe.autoreverses = true
        breathe.repeatCount = .infinity; breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(breathe, forKey: "breathe")
    }
    private func stopAura() { aura.layer?.removeAllAnimations() }

    // MARK: Mise à jour

    func apply(_ model: LucioleOverlayModel) {
        self.model = model
        guard presented else { return }
        capsuleMascot.apply(model.pose)
        bubbleMascot.apply(model.pose)
        field.placeholderString = model.placeholder
        field.isEnabled = model.composerEnabled
        followField.isEnabled = model.composerEnabled
        send.alphaValue = model.composerEnabled ? 1 : 0.4
        shareButton.alphaValue = model.contextLocked ? 0.35 : (model.contextShared ? 1 : 0.55)
        shareButton.setAccessibilityLabel(model.contextShared ? "Luciole lit la page : ne plus la partager" : "Luciole ne lit pas la page : la partager")
        noteLabel.stringValue = model.note
        updateSuggestions(model)
        updateBubble(model)
        updateDecision(model)
        updateAction(model)
        relayout()
    }

    // MARK: Décision, action, chemin

    private var decisionKey = ""
    private func updateDecision(_ model: LucioleOverlayModel) {
        let key = model.confirm.map { "c:\($0.title)|\($0.rows.map { "\($0.key)=\($0.value)" }.joined(separator: ";"))" } ?? model.question.map { "q:\($0)" } ?? ""
        decisionRect = model.decisionRect
        if key.isEmpty {
            if !decisionCard.isHidden { decisionCard.disappear() }
            decisionKey = ""
        } else {
            if key != decisionKey {
                decisionKey = key
                if let request = model.confirm { decisionCard.show(confirm: request, armed: model.confirmArmed) } else if let question = model.question { decisionCard.show(question: question) }
                decisionCard.isHidden = false; decisionCard.appear()
                if let window { NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [.announcement: decisionCard.announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue]) }
                window?.makeFirstResponder(nil); decisionCard.focusDefault()
            } else if model.confirm != nil { decisionCard.setArmed(model.confirmArmed) }
        }
        capsule.alphaValue = key.isEmpty ? 1 : 0.35
        capsule.isHidden = capsule.isHidden || mode != .capsule
    }
    private var decisionRect: CGRect?

    private func updateAction(_ model: LucioleOverlayModel) {
        if let title = model.actionTitle, model.running {
            actionPill.isHidden = false
            if pillTitle.stringValue.isEmpty { actionPill.appear() }
            pillTitle.stringValue = title
            pillStep.stringValue = "étape \(model.actionStep) sur \(model.actionTotal)"
            actionPill.setAccessibilityLabel("\(title), étape \(model.actionStep) sur \(model.actionTotal). Cliquer pour voir les étapes.")
            traceLabel.stringValue = model.actionLines.enumerated().map { "\($0.offset + 1)  \($0.element)" }.joined(separator: "\n")
            if !Motion.reduced, pillDot.layer?.animation(forKey: "pulse") == nil {
                let pulse = CABasicAnimation(keyPath: "opacity"); pulse.fromValue = 1; pulse.toValue = 0.3; pulse.duration = 0.9; pulse.autoreverses = true; pulse.repeatCount = .infinity
                pillDot.layer?.add(pulse, forKey: "pulse")
            }
        } else if !actionPill.isHidden {
            actionPill.disappear(); pillTitle.stringValue = ""; pillDot.layer?.removeAllAnimations()
            traceOpen = false; traceBubble.disappear()
        }
        updatePath(model)
    }

    /// Le chemin : une pastille de verre numérotée sur chaque élément touché, reliées dans l'ordre par des pointillés lumineux ; l'étape en cours pulse.
    private func updatePath(_ model: LucioleOverlayModel) {
        stepViews.forEach { $0.removeFromSuperview() }; stepViews = []
        guard !model.path.isEmpty else { pathLine.path = nil; pathGlow.path = nil; return }
        let line = CGMutablePath()
        for (i, item) in model.path.enumerated() {
            let center = CGPoint(x: item.rect.midX, y: item.rect.midY)
            if i == 0 { line.move(to: center) } else { line.addLine(to: center) }
        }
        pathLine.path = line; pathGlow.path = line
        for (i, item) in model.path.enumerated() {
            let badge = LucioleGlass(radius: 15, dense: false)
            badge.frame = CGRect(x: item.rect.midX - 15, y: item.rect.minY - 17, width: 30, height: 30)      // posée sur le bord haut de l'élément, qui reste lisible
            let label = NSTextField(labelWithString: "\(item.step)"); label.font = Theme.serifItalic(16); label.textColor = Theme.text; label.alignment = .center
            label.frame = CGRect(x: 0, y: 4, width: 30, height: 22); badge.content.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = true
            badge.setAccessibilityElement(true); badge.setAccessibilityLabel("Étape \(item.step)")
            addSubview(badge); stepViews.append(badge)
            let isCurrent = i == model.path.count - 1 && model.running
            if isCurrent, !Motion.reduced {
                let pulse = CABasicAnimation(keyPath: "transform.scale"); pulse.fromValue = 1; pulse.toValue = 1.18; pulse.duration = 0.8; pulse.autoreverses = true; pulse.repeatCount = .infinity
                badge.layer?.add(pulse, forKey: "pulse")
            } else if !Motion.reduced { badge.appear() }
        }
    }

    private func updateSuggestions(_ model: LucioleOverlayModel) {
        let wanted = (model.stage == .call && !model.hasConversation && model.protectedLine == nil) ? model.suggestions.map(\.label) : []
        guard wanted != shownSuggestions else { return }
        shownSuggestions = wanted
        pills.forEach { $0.disappear { } }
        let old = pills; pills = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { old.forEach { $0.removeFromSuperview() } }
        for (i, suggestion) in model.suggestions.enumerated() where i < wanted.count {
            let pill = LucioleGlassButton(title: suggestion.label, symbol: suggestion.symbol)
            pill.onClick = { [weak self] in
                guard let self else { return }
                if suggestion.web { self.field.stringValue = suggestion.fill; self.window?.makeFirstResponder(self.field); self.field.currentEditor()?.moveToEndOfDocument(nil) }
                else { self.onSubmit?(suggestion.fill) }
            }
            addSubview(pill, positioned: .below, relativeTo: capsule)
            pill.isHidden = true
            pills.append(pill)
        }
        relayout()
        for (i, pill) in pills.enumerated() { pill.appear(delay: Double(i) * 0.05) }      // cascade de 50 ms
    }

    private func updateBubble(_ model: LucioleOverlayModel) {
        let deciding = model.confirm != nil || model.question != nil
        let acting = model.actionTitle != nil && model.answer.isEmpty
        let hasContent = model.protectedLine != nil || ((!model.answer.isEmpty || model.running) && !deciding && !acting)
        if hasContent, bubble.isHidden { bubble.isHidden = false; bubble.appear() }
        if !hasContent, !bubble.isHidden { bubble.disappear() }
        guard hasContent else { return }
        if let line = model.protectedLine {
            bubbleText.attributedStringValue = NSAttributedString(string: line, attributes: [.font: Theme.sans(13), .foregroundColor: Theme.text])
        } else if model.answer.isEmpty {
            bubbleText.attributedStringValue = NSAttributedString(string: "Luciole réfléchit…", attributes: [.font: Theme.sans(13), .foregroundColor: Theme.muted])
        } else {
            bubbleText.attributedStringValue = MarkdownRenderer.attributed(model.answer + (model.running ? " ▍" : ""))
        }
        sourceRow.arrangedSubviews.forEach { sourceRow.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (i, source) in model.sources.prefix(6).enumerated() {
            guard let url = URL(string: source) else { continue }
            let pill = LucioleGlassButton(title: "\(i + 1)", symbol: nil, height: 26, font: Theme.serifItalic(15))
            pill.onClick = { [weak self] in self?.onOpenSource?(url) }
            pill.setAccessibilityLabel("Source \(i + 1) : \(url.host ?? source)")
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.widthAnchor.constraint(equalToConstant: 30).isActive = true; pill.heightAnchor.constraint(equalToConstant: 26).isActive = true
            sourceRow.addArrangedSubview(pill)
        }
        if MarkdownRenderer.deservesAPage(model.answer), !model.running {
            openPageButton.translatesAutoresizingMaskIntoConstraints = false
            if openPageButton.superview == nil { openPageButton.widthAnchor.constraint(equalToConstant: 128).isActive = true; openPageButton.heightAnchor.constraint(equalToConstant: 28).isActive = true }
            sourceRow.addArrangedSubview(openPageButton)
        }
        sourceRow.isHidden = sourceRow.arrangedSubviews.isEmpty
        followField.isHidden = model.protectedLine != nil
        noteLabel.stringValue = model.protectedLine != nil ? "" : model.note
        bubble.setAccessibilityElement(true); bubble.setAccessibilityRole(.group); bubble.setAccessibilityLabel("Réponse de Luciole")
    }

    // MARK: Placement

    #if DEBUG
    /// Dev : où sont les surfaces (pour les essais automatiques).
    var report: String {
        "overlay=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height)) hidden=\(isHidden) presented=\(presented) capsule=\(capsule.frame.integral) hidden=\(capsule.isHidden) alpha=\(capsule.alphaValue) bubble=\(bubble.frame.integral) hidden=\(bubble.isHidden) pills=\(pills.count) fan=\(fan.count) fanTip=\(fanTip.map { "\(Int($0.x)),\(Int($0.y))" } ?? "-") anchors=\(anchorRects.count) mode=\(mode) superview=\(superview.map { String(describing: type(of: $0)) } ?? "-")"
    }
    #endif

    override func layout() { super.layout(); relayout() }

    private func relayout() {
        guard presented, bounds.width > 0 else { return }
        let page = bounds.size
        let capsuleFrame = LucioleGeometry.capsule(in: page)
        capsule.frame = capsuleFrame
        if mode == .answerOnly { capsule.isHidden = true; pills.forEach { $0.isHidden = true } }
        let widths = pills.map { Double(max($0.idealWidth + 14, 170)) }
        for (pill, frame) in zip(pills, LucioleGeometry.suggestions(widths: widths, above: capsuleFrame)) { pill.frame = frame }
        guard !bubble.isHidden || model?.running == true || !(model?.answer.isEmpty ?? true) else { return }
        // La bulle : 380 pt de large ; la hauteur suit le texte, dans la limite de la place au-dessus de la capsule.
        let textWidth = LucioleGeometry.bubbleWidth - 36
        let text = bubbleText.attributedStringValue
        // La mesure du champ lui-même (celle d'un NSAttributedString oublie l'espacement entre paragraphes et l'interligne des tableaux).
        bubbleText.preferredMaxLayoutWidth = textWidth
        let needed = ceil(bubbleText.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 100_000)).height ?? text.size().height) + 6
        let chrome: CGFloat = 14 + 22 + 8 + 8 + (sourceRow.isHidden ? 0 : 26 + 8) + 10 + (followField.isHidden ? 0 : 34) + 8 + 14 + 12
        let maxText = max(80, capsuleFrame.minY - 40 - chrome - 20)
        let textHeight = min(needed, maxText)
        bubbleHeight = textHeight + chrome
        bubbleText.frame = CGRect(x: 0, y: 0, width: textWidth, height: needed)
        bubbleScroll.documentView?.frame = CGRect(x: 0, y: 0, width: textWidth, height: needed)
        bubbleScroll.documentView?.autoresizingMask = []
        if let heightConstraint = bubbleScroll.constraints.first(where: { $0.firstAttribute == .height }) { heightConstraint.constant = textHeight }
        else { bubbleScroll.heightAnchor.constraint(equalToConstant: textHeight).isActive = true }
        // Pastille d'action (en haut, au centre), liste des étapes dépliée dessous.
        let pillWidth = min(560, page.width * 0.7)
        actionPill.frame = CGRect(x: (page.width - pillWidth) / 2, y: 14, width: pillWidth, height: 42)
        let lines = traceLabel.stringValue.split(separator: "\n").count
        traceBubble.frame = CGRect(x: actionPill.frame.minX, y: actionPill.frame.maxY + 8, width: pillWidth, height: CGFloat(min(lines, 12)) * 20 + 28)
        traceBubble.isHidden = !(traceOpen && !actionPill.isHidden)
        // La carte de décision, près de l'élément (ou en bas à droite sans élément), reliée à lui par des pointillés.
        if !decisionCard.isHidden {
            decisionCard.frame = CGRect(x: 0, y: 0, width: LucioleGeometry.bubbleWidth, height: 1000)
            decisionCard.layoutSubtreeIfNeeded()
            let height = max(decisionCard.content.fittingSize.height, 160)
            let placed = LucioleGeometry.bubble(height: Double(height), anchor: decisionRect, page: page, avoiding: nil)
            decisionCard.frame = placed.frame
            if let rect = decisionRect, placed.side != .corner {
                let link = LucioleGeometry.thread(from: placed.frame, to: rect)
                let curve = CGMutablePath(); curve.move(to: link.start); curve.addQuadCurve(to: link.end, control: link.control)
                thread.path = curve; threadHalo.path = curve; thread.lineDashPattern = [2, 6]; threadHalo.lineDashPattern = [2, 6]
            }
            bubble.isHidden = true
            return
        }
        thread.lineDashPattern = nil; threadHalo.lineDashPattern = nil
        let anchor = LucioleGeometry.anchor(of: anchorRects, page: page)
        let placed = LucioleGeometry.bubble(height: Double(bubbleHeight), anchor: anchor, page: page, avoiding: mode == .answerOnly ? nil : capsuleFrame)
        bubble.frame = placed.frame
        drawAnchor(anchor: anchor, bubble: placed.frame, drawThread: placed.side != .corner && !bubble.isHidden)
    }

    // MARK: Passage : surlignage et fil de lumière (dessinés ici, jamais dans le site)

    private func drawAnchor(anchor: CGRect?, bubble: CGRect, drawThread: Bool) {
        let path = CGMutablePath()
        for rect in anchorRects { path.addRoundedRect(in: rect.insetBy(dx: -2, dy: -1), cornerWidth: 4, cornerHeight: 4) }
        highlight.path = anchorRects.isEmpty ? nil : path
        guard drawThread, let anchor else { thread.path = nil; threadHalo.path = nil; return }
        let line = LucioleGeometry.thread(from: bubble, to: anchor)
        let curve = CGMutablePath()
        curve.move(to: line.start); curve.addQuadCurve(to: line.end, control: line.control)
        thread.path = curve; threadHalo.path = curve
    }

    func setAnchor(_ rects: [CGRect]) { anchorRects = rects; relayout() }
    func clearAnchor() { anchorRects = []; highlight.path = nil; thread.path = nil; threadHalo.path = nil }

    // MARK: Éventail (sélection)

    /// Luciole vole jusqu'au bout de la dernière ligne sélectionnée et déploie ses trois gestes ; Réserve : sans écran de réponse ouvert.
    func showFan(tip: CGPoint, from toolbarButton: NSRect?) {
        guard !presented else { return }
        let reuse = fanTip != nil
        fanTip = tip
        isHidden = false
        let placed = LucioleGeometry.fan(tip: tip, count: 3, size: CGSize(width: 130, height: 36), page: bounds.size)
        if fan.isEmpty {
            fanGestures = SelectionPassage.Gesture.allCases
            for gesture in fanGestures {
                let button = LucioleGlassButton(title: gesture.title, symbol: gesture.symbol, height: 36, font: Theme.sans(13.5, .medium), keyHint: gesture.key.uppercased())
                button.onClick = { [weak self] in self?.onGesture?(gesture) }
                button.setAccessibilityLabel("\(gesture.title) (touche \(gesture.key.uppercased()))")
                addSubview(button); fan.append(button)
            }
            fanMascot.apply(SelectionPassage.Gesture.explain == .explain ? LucioleStage.selection.pose : .idle)
            fanMascot.isHidden = false
            installKeyMonitor()
        }
        fanMascot.frame = CGRect(x: tip.x - 21, y: tip.y - 21, width: 42, height: 42)
        for (button, frame) in zip(fan, placed.frames) { button.frame = frame }
        if !reuse { for (i, button) in fan.enumerated() { button.appear(delay: 0.1 + Double(i) * 0.05) } }      // cascade de 50 ms
        if !reuse, !Motion.reduced, let button = toolbarButton, let window, let host = fanMascot.layer {
            let from = convert(window.contentView?.convert(button, from: nil) ?? button, from: nil)
            let move = CABasicAnimation(keyPath: "transform.translation"); move.fromValue = NSValue(size: NSSize(width: from.midX - tip.x, height: from.midY - tip.y)); move.toValue = NSValue(size: .zero)
            let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = 28.0 / 42.0; scale.toValue = 1
            let group = CAAnimationGroup(); group.animations = [move, scale]; group.duration = 0.8; group.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.15, 1)
            host.add(group, forKey: "flight")
        }
    }

    func hideFan() {
        guard !fan.isEmpty || fanTip != nil else { return }
        fanTip = nil
        let old = fan; fan = []
        old.forEach { button in button.disappear { button.removeFromSuperview() } }
        fanMascot.isHidden = true
        if !presented { removeKeyMonitor(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in if let self, !self.presented, self.fan.isEmpty { self.isHidden = true } } }
    }

    var fanIsVisible: Bool { !fan.isEmpty }

    /// Une bulle ancrée sans capsule : la réponse à un geste (Expliquer, Traduire).
    func presentAnswerOnly() {
        hideFan()
        mode = .answerOnly
        presented = true
        isHidden = false
        installKeyMonitor()
    }

    // MARK: Clavier

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            if !self.decisionCard.isHidden, self.presented {                                          // une décision est attendue : Échap annule, Entrée ne valide jamais
                if event.keyCode == 53 { self.decisionCard.onCancel?(); return nil }
                if event.keyCode == 36 || event.keyCode == 76 { self.decisionCard.returnPressed(); return nil }
                return event
            }
            if event.keyCode == 53, self.presented || !self.fan.isEmpty {                        // Échap
                if !self.presented { self.hideFan(); return nil }
                if self.model?.running == true { self.onStop?() } else { self.onClose?() }
                return nil
            }
            if plain, !self.fan.isEmpty, !self.presented, let key = event.charactersIgnoringModifiers?.first, let gesture = SelectionPassage.Gesture.gesture(forKey: key) {
                self.onGesture?(gesture); return nil                                              // les touches E, T, G pendant que l'éventail est visible
            }
            return event
        }
    }
    private func removeKeyMonitor() { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil }
}
