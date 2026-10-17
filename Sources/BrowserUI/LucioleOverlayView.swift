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
        let interactive: [NSView] = [capsule, bubble] + pills
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

    func focusComposer() { window?.makeFirstResponder(field) }

    // MARK: Présentation

    /// L'appel : Luciole quitte la barre d'outils (`from`, en coordonnées de fenêtre) et descend dans la capsule.
    func present(from toolbarButton: NSRect?) {
        guard !presented else { return }
        presented = true; anchorFrame = toolbarButton
        isHidden = false
        layoutSubtreeIfNeeded(); relayout()
        capsule.appear()
        flyMascot(from: toolbarButton)
        startAura()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.presented, self.model?.stage == .call, event.window === self.window else { return event }
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
        pills.forEach { $0.disappear() }
        bubble.disappear()
        capsule.disappear { [weak self] in
            guard let self, !self.presented else { return }
            self.isHidden = true
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
        relayout()
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
        let hasContent = model.protectedLine != nil || !model.answer.isEmpty || model.running
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
        "overlay=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height)) hidden=\(isHidden) presented=\(presented) capsule=\(capsule.frame.integral) hidden=\(capsule.isHidden) alpha=\(capsule.alphaValue) bubble=\(bubble.frame.integral) hidden=\(bubble.isHidden) pills=\(pills.count) superview=\(superview.map { String(describing: type(of: $0)) } ?? "-")"
    }
    #endif

    override func layout() { super.layout(); relayout() }

    private func relayout() {
        guard presented, bounds.width > 0 else { return }
        let page = bounds.size
        let capsuleFrame = LucioleGeometry.capsule(in: page)
        capsule.frame = capsuleFrame
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
        let placed = LucioleGeometry.bubble(height: Double(bubbleHeight), anchor: nil, page: page, avoiding: capsuleFrame)
        bubble.frame = placed.frame
    }
}
