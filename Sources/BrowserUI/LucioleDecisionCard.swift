import AppKit
import BrowserCore

/// La carte où Luciole s'arrête et laisse décider : une validation (envoi, paiement, connexion, téléchargement) ou une question. Verre dense, 380 pt.
/// Son contenu vient d'Orée (`ConfirmRequest` construit à partir des champs réels du formulaire, secrets masqués), jamais du texte du modèle.
/// Annuler est le choix par défaut ; « Valider » ne répond qu'après 1,2 s ; Entrée ne valide jamais ; Échap annule.
@MainActor
final class LucioleDecisionCard: LucioleGlass {
    enum Kind { case confirm, question, model }
    var onPrimary: ((String?) -> Void)?
    var onCancel: (() -> Void)?

    private let kicker = NSTextField(labelWithString: "Je m'arrête ici · à toi de décider")
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let rowsStack = NSStackView()
    private let field = NSTextField()
    private let cancel = LucioleGlassButton(title: "Annuler", symbol: nil, height: 36, font: Theme.sans(13.5, .semibold))
    private let primary = SurfaceView(fill: Theme.accent, cornerRadius: 18)
    private let primaryLabel = NSTextField(labelWithString: "")
    private(set) var kind: Kind = .confirm
    private var armed = true

    init() {
        super.init(radius: 22, dense: true)
        let c = content
        kicker.font = Theme.sans(11.5, .semibold); kicker.textColor = Theme.accent
        titleLabel.font = Theme.sans(16, .semibold); titleLabel.textColor = Theme.text
        detail.font = Theme.sans(12.5); detail.textColor = Theme.muted
        rowsStack.orientation = .vertical; rowsStack.alignment = .leading; rowsStack.spacing = 4
        field.placeholderString = "Votre réponse…"; field.font = Theme.sans(14); field.isBordered = false; field.drawsBackground = true; field.backgroundColor = Theme.hover
        field.focusRingType = .none; field.wantsLayer = true; field.layer?.cornerRadius = 10
        primaryLabel.font = Theme.sans(13.5, .semibold); primaryLabel.textColor = Theme.onAccent
        primary.elevation = .one; primary.addSubview(primaryLabel)
        primaryLabel.translatesAutoresizingMaskIntoConstraints = false
        primary.setAccessibilityElement(true); primary.setAccessibilityRole(.button)
        for v in [kicker, titleLabel, rowsStack, detail, field, cancel, primary] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; c.addSubview(v) }
        NSLayoutConstraint.activate([
            kicker.topAnchor.constraint(equalTo: c.topAnchor, constant: 16), kicker.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 18),
            titleLabel.topAnchor.constraint(equalTo: kicker.bottomAnchor, constant: 6), titleLabel.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 18), titleLabel.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -18),
            rowsStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10), rowsStack.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 18), rowsStack.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -18),
            field.topAnchor.constraint(equalTo: rowsStack.bottomAnchor, constant: 8), field.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 18), field.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -18), field.heightAnchor.constraint(equalToConstant: 34),
            detail.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8), detail.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 18), detail.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -18),
            cancel.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 14), cancel.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 18), cancel.widthAnchor.constraint(equalToConstant: 96), cancel.heightAnchor.constraint(equalToConstant: 36),
            primary.centerYAnchor.constraint(equalTo: cancel.centerYAnchor), primary.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -18), primary.heightAnchor.constraint(equalToConstant: 36),
            primaryLabel.leadingAnchor.constraint(equalTo: primary.leadingAnchor, constant: 18), primaryLabel.trailingAnchor.constraint(equalTo: primary.trailingAnchor, constant: -18), primaryLabel.centerYAnchor.constraint(equalTo: primary.centerYAnchor),
            primary.leadingAnchor.constraint(greaterThanOrEqualTo: cancel.trailingAnchor, constant: 12),
            c.bottomAnchor.constraint(equalTo: cancel.bottomAnchor, constant: 16),
        ])
        cancel.onClick = { [weak self] in self?.onCancel?() }
        primary.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(primaryTapped)))
        setAccessibilityElement(true); setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Les rôles « alerte » n'existent pas dans AppKit : le groupe est étiqueté « Alerte » et annoncé à VoiceOver quand il apparaît.
    func show(confirm request: ConfirmRequest, armed: Bool) {
        kind = .confirm
        primary.isHidden = false; cancel.setTitle("Annuler")
        kicker.stringValue = "Je m'arrête ici · à toi de décider"
        titleLabel.stringValue = request.title
        detail.stringValue = request.warning
        field.isHidden = true
        rowsStack.arrangedSubviews.forEach { rowsStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for row in request.rows.prefix(8) {
            let line = NSTextField(wrappingLabelWithString: "")
            let text = NSMutableAttributedString(string: row.key + "  ", attributes: [.font: Theme.sans(12), .foregroundColor: Theme.muted])
            text.append(NSAttributedString(string: row.value, attributes: [.font: Theme.sans(13, .medium), .foregroundColor: Theme.text]))
            line.attributedStringValue = text; line.maximumNumberOfLines = 2; line.lineBreakMode = .byTruncatingTail
            line.preferredMaxLayoutWidth = LucioleGeometry.bubbleWidth - 36
            rowsStack.addArrangedSubview(line)
        }
        rowsStack.isHidden = request.rows.isEmpty
        primaryLabel.stringValue = Self.verb(for: request.title)
        setArmed(armed)
        setAccessibilityLabel("Alerte, validation requise. \(request.title) \(request.rows.map { "\($0.key) : \($0.value)" }.joined(separator: ". ")). \(request.warning)")
        primary.setAccessibilityLabel(primaryLabel.stringValue)
    }

    func show(question: String) {
        kind = .question
        primary.isHidden = false; cancel.setTitle("Annuler")
        kicker.stringValue = "Luciole a besoin d'une précision"
        titleLabel.stringValue = question
        detail.stringValue = "Votre réponse n'est envoyée qu'au fournisseur choisi, et ne sert qu'à cette tâche."
        rowsStack.isHidden = true; field.isHidden = false; field.stringValue = ""
        primaryLabel.stringValue = "Répondre"
        setArmed(true)
        setAccessibilityLabel("Question de Luciole : \(question)")
        primary.setAccessibilityLabel("Répondre")
    }

    /// L'état du modèle (à installer, injoignable, clé manquante…) : une carte sobre, avec « Réessayer » quand il y a quelque chose à retenter.
    func show(model title: String, text: String, primary action: String?) {
        kind = .model
        kicker.stringValue = "Luciole n'est pas prête"
        titleLabel.stringValue = title
        detail.stringValue = text
        rowsStack.isHidden = true; field.isHidden = true
        primary.isHidden = action == nil
        primaryLabel.stringValue = action ?? ""
        cancel.setTitle("Fermer")
        setArmed(true)
        setAccessibilityLabel("Luciole n'est pas prête. \(title). \(text)")
        primary.setAccessibilityLabel(action ?? "")
    }

    /// « Valider » ne répond qu'après 1,2 s : impossible à valider d'un clic réflexe.
    func setArmed(_ on: Bool) { armed = on; primary.alphaValue = on ? 1 : 0.4 }

    var isArmed: Bool { armed }

    @objc private func primaryTapped() {
        guard armed else { return }
        if kind == .model { onPrimary?(nil); return }
        if kind == .question {
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            onPrimary?(text)
        } else { onPrimary?(nil) }
    }

    /// Entrée ne valide jamais : sur une validation, elle annule ; sur une question, elle envoie la réponse écrite.
    func returnPressed() { if kind == .confirm || kind == .model { onCancel?() } else { primaryTapped() } }

    func focusDefault() { window?.makeFirstResponder(kind == .question ? field : nil) }

    static func verb(for title: String) -> String {
        let t = title.lowercased()
        if t.contains("achat") { return "Valider l'achat" }
        if t.contains("télécharger") { return "Télécharger" }
        if t.contains("connecter") { return "Se connecter" }
        if t.contains("remplir") { return "Autoriser" }
        return "Valider l'envoi"
    }

    /// L'étiquette de la carte pour l'annonce VoiceOver.
    var announcement: String { accessibilityLabel() ?? "" }
}

/// Le voile : toute la zone de page s'assombrit (noir à 50 %) sauf un trou autour de l'élément qui va être cliqué, cerclé d'accent (3 pt + halo de 10 pt).
/// Il prend les clics (rien ne se passe sous lui pendant qu'une décision est attendue) ; posé sous la mascotte pour qu'elle reste lumineuse.
@MainActor
final class LucioleDimView: NSView {
    private let veil = CAShapeLayer(), ring = CAShapeLayer(), halo = CAShapeLayer()
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : self }
    override func mouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true; isHidden = true
        veil.fillRule = .evenOdd; veil.fillColor = NSColor.black.withAlphaComponent(0.5).cgColor
        for l in [ring, halo] { l.fillColor = nil }
        ring.strokeColor = Theme.accent.cgColor; ring.lineWidth = 3
        halo.strokeColor = Theme.accent.withAlphaComponent(0.35).cgColor; halo.lineWidth = 10
        for l in [veil, halo, ring] as [CALayer] { layer?.addSublayer(l) }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var hole: CGRect?
    override func layout() { super.layout(); if !isHidden { redraw() } }

    /// `hole` en coordonnées de cette vue ; nil : tout est sombre.
    func show(hole: CGRect?) {
        self.hole = hole
        redraw()
        guard isHidden else { return }
        isHidden = false
        guard !Motion.reduced else { return }
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.3
        layer?.add(fade, forKey: "in")
    }

    private func redraw() {
        let outer = CGRect(origin: .zero, size: bounds.size)
        let path = CGMutablePath(); path.addRect(outer)
        if let hole {
            let rect = hole.insetBy(dx: -6, dy: -6)
            path.addRoundedRect(in: rect, cornerWidth: 10, cornerHeight: 10)
            let ringPath = CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)
            ring.path = ringPath; halo.path = ringPath
        } else { ring.path = nil; halo.path = nil }
        veil.path = path
        veil.frame = bounds; ring.frame = bounds; halo.frame = bounds
    }

    func hide() {
        guard !isHidden else { return }
        if Motion.reduced { isHidden = true; return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; animator().alphaValue = 0 }, completionHandler: { [weak self] in self?.isHidden = true; self?.alphaValue = 1 })
    }
}
