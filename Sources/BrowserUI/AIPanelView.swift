import AppKit
import BrowserCore

// Le panneau Luciole, fidèle à la fiche de spécifications (mesures en points, jetons de couleur par nom) :
// fond « chrome », en-tête 44, puce de contexte 28, fil à marges de 16, cartes à rayon 14, composeur à rayon 10.

/// Un message de la conversation d'un onglet. Une réponse de l'IA porte la trace des actions faites pour la produire, et ses sources.
struct AIMessage {
    enum Role { case user, assistant }
    var role: Role
    var text: String
    var trace: [AgentTraceItem] = []
    var sources: [String] = []
    var title = ""                 // titre de la tâche, pour la carte de trace
    var thinking = ""              // ce que le modèle « pense » avant de répondre (en grisé, tant que rien n'est écrit)
    var stoppedAtStep: Int?        // arrêtée par la personne
    var capped = false             // plafond d'étapes atteint
}

/// Ce que le fil affiche en plus des messages : une action à valider (épinglée au-dessus du composeur) ou une question de l'IA (dans le fil).
struct AIPending: Equatable {
    enum Kind: Equatable { case confirm(ConfirmRequest), question(String) }
    var kind: Kind
    var since: Date
    /// « Valider » ne répond qu'après 1,2 s : impossible à valider d'un clic réflexe.
    var armed: Bool { Date().timeIntervalSince(since) >= 1.2 }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// La poignée entre la page et le panneau : 8 pt de large, un repère de 3 × 36 qui devient 3 × 56 en couleur d'accent au survol et pendant le glisser,
/// avec l'étiquette de la largeur (« 412 pt »). Flèches : ±20 pt. Redimensionne de 320 à 520 pt.
@MainActor
private final class PanelHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    var currentWidth: () -> CGFloat = { 380 }
    private var startX: CGFloat = 0, startWidth: CGFloat = 0
    private var hovering = false { didSet { needsDisplay = true } }
    private var dragging = false { didSet { needsDisplay = true; tagLabel.isHidden = !dragging; updateTag() } }
    private let tagLabel = NSTextField(labelWithString: "")
    private let tagBox = SurfaceView(fill: Theme.text, cornerRadius: 5)

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        tagLabel.font = Theme.sans(11, .semibold); tagLabel.textColor = Theme.page
        tagLabel.translatesAutoresizingMaskIntoConstraints = false
        tagBox.addSubview(tagLabel)
        tagBox.isHidden = true
        addSubview(tagBox)
        NSLayoutConstraint.activate([
            tagLabel.leadingAnchor.constraint(equalTo: tagBox.leadingAnchor, constant: 7), tagLabel.trailingAnchor.constraint(equalTo: tagBox.trailingAnchor, constant: -7),
            tagLabel.topAnchor.constraint(equalTo: tagBox.topAnchor, constant: 3), tagLabel.bottomAnchor.constraint(equalTo: tagBox.bottomAnchor, constant: -3),
            tagBox.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -50), tagBox.trailingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func updateTag() { tagLabel.stringValue = "\(Int(currentWidth())) pt"; setAccessibilityLabel("Largeur du panneau Luciole, \(Int(currentWidth())) points") }

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { startX = NSEvent.mouseLocation.x; startWidth = currentWidth(); dragging = true }
    override func mouseDragged(with event: NSEvent) { onDrag?(startWidth + (startX - NSEvent.mouseLocation.x)); updateTag() }
    override func mouseUp(with event: NSEvent) { dragging = false; onEnd?() }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onDrag?(currentWidth() + 20); onEnd?(); updateTag()      // ←
        case 124: onDrag?(currentWidth() - 20); onEnd?(); updateTag()      // →
        default: super.keyDown(with: event)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let active = hovering || dragging
        let h: CGFloat = active ? 56 : 36
        let rect = NSRect(x: bounds.midX - 1.5, y: bounds.midY - h / 2, width: 3, height: h)
        (active ? Theme.accent : NSColor.clear).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        if window?.firstResponder === self {
            Theme.accent.setStroke()
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: 3, yRadius: 3); ring.lineWidth = 2; ring.stroke()
        }
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
}

/// Le champ du composeur : prévient quand il prend ou perd le focus (l'anneau d'accent de 2 pt suit).
private final class ComposerTextView: NSTextView {
    var onFocus: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool { let r = super.becomeFirstResponder(); if r { onFocus?(true) }; return r }
    override func resignFirstResponder() -> Bool { let r = super.resignFirstResponder(); if r { onFocus?(false) }; return r }
}

/// « Valider » : inactif pendant 1,2 s, avec une barre de remplissage qui se remplit ; Entrée ne le déclenche jamais, Espace oui (une fois actif).
@MainActor
private final class ArmedButton: NSView {
    var onClick: (() -> Void)?
    private let title: String
    private let fillLayer = CALayer()
    private let label = NSTextField(labelWithString: "")
    private(set) var armed = false
    private var hover = false { didSet { needsDisplay = true } }

    init(_ title: String, since: Date) {
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6; layer?.masksToBounds = true
        layer?.backgroundColor = Theme.cg(Theme.accent.withAlphaComponent(0.35), in: self)
        layer?.addSublayer(fillLayer)
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        label.stringValue = title; label.font = Theme.sans(12.5, .semibold); label.textColor = Theme.onAccent
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        label.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true; label.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        setAccessibilityElement(true); setAccessibilityRole(.button)
        let remaining = max(0, 1.2 - Date().timeIntervalSince(since))
        armed = remaining == 0
        setAccessibilityLabel(armed ? title : "\(title) (disponible dans un instant)")
        if !armed {
            let fill = CABasicAnimation(keyPath: "bounds.size.width")
            fill.duration = remaining; fill.fillMode = .forwards; fill.isRemovedOnCompletion = false
            fillAnimation = fill
            Task { try? await Task.sleep(for: .seconds(remaining)); self.armed = true; self.setAccessibilityLabel(self.title); self.needsDisplay = true }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var fillAnimation: CABasicAnimation?
    override var acceptsFirstResponder: Bool { true }
    override func layout() {
        super.layout()
        layer?.backgroundColor = Theme.cg(Theme.accent.withAlphaComponent(0.35), in: self)
        fillLayer.frame = bounds
        fillLayer.backgroundColor = Theme.cg(Theme.accent, in: self)
        if let fill = fillAnimation, !armed {
            fillLayer.anchorPoint = CGPoint(x: 0, y: 0.5); fillLayer.frame = CGRect(x: 0, y: 0, width: 0, height: bounds.height)
            fill.fromValue = 0; fill.toValue = bounds.width
            fillLayer.add(fill, forKey: "fill")
            fillAnimation = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + fill.duration) { [weak self] in self?.fillLayer.frame = self?.bounds ?? .zero }
        } else if armed { fillLayer.frame = bounds }
    }
    override func draw(_ dirtyRect: NSRect) {
        // Fond atténué (accent à 35 %) sous la barre de remplissage ; plein quand actif.
        // Le fond atténué (accent à 35 %) est celui du calque ; la barre de remplissage passe dessus, puis le texte (sous-vue).
        if armed, hover { NSColor.black.withAlphaComponent(0.12).setFill(); bounds.fill() }
        if window?.firstResponder === self {
            Theme.accent.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: -2, dy: -2), xRadius: 8, yRadius: 8); ring.lineWidth = 2; ring.stroke()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { if armed { onClick?() } }
    override func keyDown(with event: NSEvent) { if event.keyCode == 49, armed { onClick?() } else if event.keyCode != 36 { super.keyDown(with: event) } }   // Entrée ne valide jamais
    override func accessibilityPerformPress() -> Bool { if armed { onClick?() }; return armed }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
}

/// La carte « Validation requise » reçoit le clavier : Échap annule, Entrée ne fait rien.
@MainActor
private final class ConfirmCardView: SurfaceView {
    var onCancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()          // Échap
        case 36, 76: break            // Entrée ne valide jamais
        default: super.keyDown(with: event)
        }
    }
}

/// Le panneau IA : une colonne collée au bord droit de la fenêtre. Il ne décide de rien : il montre ce que `AIPanelController` lui donne.
@MainActor
final class AIPanelView: SurfaceView, NSTextViewDelegate {
    enum Dot { case accent, outline, alert, muted }
    enum ModelAction { case download, later, cancelDownload, retry, resume, deleteReceived }

    struct ModelScreen {
        var title: String
        var text: String
        var facts: [(symbol: String, bold: String, rest: String)] = []
        var progress: Double?               // 0...1 ; nil + `indeterminate` : barre indéterminée
        var indeterminate = false
        var progressLeft = "", progressRight = ""
        var primary: (title: String, action: ModelAction)?
        var secondary: (title: String, action: ModelAction)?
        var footnote: String?
    }
    enum Mode {
        case conversation
        case empty(title: String, text: String, suggestions: [(symbol: String, label: String, fill: String, web: Bool)])
        case model(ModelScreen)
    }
    struct Screen {
        var pose: LucioleState
        var chipText: String
        var chipDot: Dot
        var contextText: String
        var contextLetter: String?
        var contextShared: Bool
        var contextLocked: Bool
        var mode: Mode
        var placeholder: String
        var composerEnabled: Bool
        var running: Bool
        var showsStop = true       // faux pendant une validation : Annuler fait le même travail, en plus clair
        var note: String
    }

    // En-tête
    let mascot = LucioleView(size: 28)
    private let title = NSTextField(labelWithString: "Luciole")
    private let chip = SurfaceView(fill: Theme.hover, cornerRadius: Theme.pill)
    private let chipDot = SurfaceView(fill: Theme.accent, cornerRadius: 3.5)
    private let chipLabel = NSTextField(labelWithString: "")
    private let historyButton = ChromeIconButton(symbol: "clock.arrow.circlepath", label: "Discussions précédentes", size: 28, pointSize: 14)
    private let newChat = ChromeIconButton(symbol: "square.and.pencil", label: "Nouvelle conversation", size: 28, pointSize: 14)
    private let closeButton = ChromeIconButton(symbol: "xmark", label: "Fermer le panneau", size: 28, pointSize: 13)
    // Puce de contexte
    private let contextPill = SurfaceView(fill: Theme.hover, cornerRadius: Theme.pill)
    private let contextBadge = LetterBadgeView(size: 16, cornerRadius: 4)
    private let contextIcon = NSImageView()
    private let contextLabel = NSTextField(labelWithString: "")
    private let eyeButton = ChromeIconButton(symbol: "eye", label: "Ne pas partager cette page", size: 28, pointSize: 14)
    // Corps
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let stack = NSStackView()
    private let emptyHost = NSView()
    private let emptyStack = NSStackView()
    private let questionField = NSTextField()
    private var expandedTraces: Set<Int> = []
    private var collapsedTraces: Set<Int> = []
    private var currentMode = "conversation"
    // Carte de confirmation (épinglée au-dessus du composeur)
    private let pinnedHost = NSView()
    private var pinnedHeight: NSLayoutConstraint!
    // Composeur
    private let composer = ComposerTextView()
    private let composerScroll = NSScrollView()
    private let composerBox = FocusingSurface(fill: Theme.field, cornerRadius: 10)
    private let placeholder = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "↵ envoyer  ·  ⇧↵ à la ligne")
    private let send = PressableSurface(fill: Theme.accent, cornerRadius: 14)
    private let sendIcon = NSImageView()
    private let stopPill = PressableSurface(fill: Theme.text, cornerRadius: Theme.pill)
    private let note = NSTextField(labelWithString: "")
    private var composerHeight: NSLayoutConstraint!
    private let handle = PanelHandle()

    private var running = false
    private var canAsk = false
    private var composerFocused = false { didSet { updateRing() } }
    private func updateRing() { composerBox.border = composerFocused && canAsk && !running ? Theme.accent : nil; composerBox.borderWidth = 2 }

    var onSubmit: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onModelAction: ((ModelAction) -> Void)?
    var onClose: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onHistory: ((NSView) -> Void)?
    var onToggleShare: (() -> Void)?
    var onConfirm: ((Bool) -> Void)?
    var onAnswer: ((String?) -> Void)?
    var onCopy: ((String) -> Void)?
    var onOpenPage: ((String) -> Void)?
    var onOpenSource: ((URL) -> Void)?
    var onRefresh: (() -> Void)?
    var onResize: ((CGFloat) -> Void)? { didSet { handle.onDrag = onResize } }
    var onResizeEnd: (() -> Void)? { didSet { handle.onEnd = onResizeEnd } }
    var currentWidth: () -> CGFloat = { 380 } { didSet { handle.currentWidth = currentWidth } }

    init() {
        super.init(fill: Theme.chrome)
        setAccessibilityElement(false)
        setAccessibilityLabel("Panneau Luciole")
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Le panneau passe par-dessus la page sous 900 pt : ombre-3 et coin haut-gauche à 14.
    func setOverlay(_ overlay: Bool) {
        elevation = overlay ? .three : nil
        cornerRadius = overlay ? 14 : 0
        maskedCorners = [.layerMinXMaxYCorner, .layerMinXMinYCorner]
        needsDisplay = true
    }

    // MARK: Construction

    private func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = Theme.text, lines: Int = 0, lineHeight: CGFloat = 1.5) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: string)
        field.font = Theme.sans(size, weight); field.textColor = color; field.maximumNumberOfLines = lines
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isSelectable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setLineHeight(field, lineHeight)
        return field
    }
    private func setLineHeight(_ field: NSTextField, _ multiple: CGFloat) {
        let style = NSMutableParagraphStyle(); style.lineHeightMultiple = multiple
        let value = NSMutableAttributedString(string: field.stringValue, attributes: [.font: field.font ?? Theme.sans(13), .foregroundColor: field.textColor ?? Theme.text, .paragraphStyle: style])
        field.attributedStringValue = value
    }
    private func serif(_ string: String, size: CGFloat, lineHeight: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: string)
        let style = NSMutableParagraphStyle(); style.lineHeightMultiple = lineHeight
        field.attributedStringValue = NSAttributedString(string: string, attributes: [.font: Theme.serifItalic(size), .foregroundColor: Theme.text, .paragraphStyle: style])
        field.maximumNumberOfLines = 0; field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    private func symbol(_ name: String, size: CGFloat = 14, color: @escaping () -> NSColor) -> NSImageView {
        let view = NSImageView(image: .oreeSymbol(name, size: size, weight: .regular, color: color))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }
    private func rule() -> NSView { let line = SurfaceView(fill: Theme.line); line.heightAnchor.constraint(equalToConstant: 1).isActive = true; return line }
    private func column(_ views: [NSView], spacing: CGFloat, alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical; s.alignment = alignment; s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }
    private func row(_ views: [NSView], spacing: CGFloat, alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal; s.alignment = alignment; s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }
    private func fullWidth(_ view: NSView, in stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func build() {
        // En-tête : 44, marges 10 / 8, écart 8.
        title.font = Theme.sans(14, .semibold); title.textColor = Theme.text
        chipDot.translatesAutoresizingMaskIntoConstraints = false
        chipLabel.font = Theme.sans(11.5, .semibold); chipLabel.textColor = Theme.muted
        chipLabel.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(chipDot); chip.addSubview(chipLabel)
        NSLayoutConstraint.activate([
            chip.heightAnchor.constraint(equalToConstant: 22),
            chipDot.widthAnchor.constraint(equalToConstant: 7), chipDot.heightAnchor.constraint(equalToConstant: 7),
            chipDot.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 9), chipDot.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            chipLabel.leadingAnchor.constraint(equalTo: chipDot.trailingAnchor, constant: 5), chipLabel.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -9),
            chipLabel.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
        ])
        chip.setAccessibilityElement(true)
        newChat.onClick = { [weak self] in self?.onNewChat?() }
        historyButton.onClick = { [weak self] in guard let self else { return }; self.onHistory?(self.historyButton) }
        closeButton.onClick = { [weak self] in self?.onClose?() }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = row([mascot, title, chip, spacer, historyButton, newChat, closeButton], spacing: 4)
        header.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        chip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Puce de contexte : 28, pastille, fond survol ; l'œil (28) à droite coupe ou rétablit le partage.
        contextLabel.font = Theme.sans(12.5); contextLabel.textColor = Theme.text; contextLabel.lineBreakMode = .byTruncatingTail
        contextLabel.translatesAutoresizingMaskIntoConstraints = false
        contextBadge.translatesAutoresizingMaskIntoConstraints = false
        contextIcon.translatesAutoresizingMaskIntoConstraints = false
        for v in [contextBadge, contextIcon, contextLabel] as [NSView] { contextPill.addSubview(v) }
        NSLayoutConstraint.activate([
            contextPill.heightAnchor.constraint(equalToConstant: 28),
            contextBadge.leadingAnchor.constraint(equalTo: contextPill.leadingAnchor, constant: 6), contextBadge.centerYAnchor.constraint(equalTo: contextPill.centerYAnchor),
            contextIcon.leadingAnchor.constraint(equalTo: contextPill.leadingAnchor, constant: 8), contextIcon.centerYAnchor.constraint(equalTo: contextPill.centerYAnchor),
            contextLabel.leadingAnchor.constraint(equalTo: contextPill.leadingAnchor, constant: 28), contextLabel.trailingAnchor.constraint(equalTo: contextPill.trailingAnchor, constant: -10),
            contextLabel.centerYAnchor.constraint(equalTo: contextPill.centerYAnchor),
        ])
        contextPill.setAccessibilityElement(true)
        eyeButton.onClick = { [weak self] in self?.onToggleShare?() }
        let contextRow = row([contextPill, eyeButton], spacing: 4)
        contextRow.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        contextPill.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Fil de conversation : une pile verticale dans un défilement ; marges de 16, 16 entre messages.
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 10), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
        ])

        // État vide / états du modèle : une pile centrée verticalement, marges de 16.
        emptyStack.orientation = .vertical; emptyStack.alignment = .leading; emptyStack.spacing = 16
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        emptyHost.translatesAutoresizingMaskIntoConstraints = false
        emptyHost.addSubview(emptyStack)
        NSLayoutConstraint.activate([
            emptyStack.leadingAnchor.constraint(equalTo: emptyHost.leadingAnchor, constant: 16), emptyStack.trailingAnchor.constraint(equalTo: emptyHost.trailingAnchor, constant: -16),
            emptyStack.centerYAnchor.constraint(equalTo: emptyHost.centerYAnchor, constant: -12),
            emptyStack.topAnchor.constraint(greaterThanOrEqualTo: emptyHost.topAnchor, constant: 8),
        ])

        // Carte épinglée (confirmation) : au-dessus du composeur, elle ne défile pas.
        pinnedHost.translatesAutoresizingMaskIntoConstraints = false
        pinnedHeight = pinnedHost.heightAnchor.constraint(equalToConstant: 0)
        pinnedHeight.isActive = true

        // Composeur : fond champ, rayon 10, marges 8/8/8/12 ; 2 à 5 lignes ; anneau d'accent de 2 pt au focus.
        composer.font = Theme.sans(13); composer.textColor = Theme.text
        composer.drawsBackground = false; composer.isRichText = false; composer.allowsUndo = true
        composer.textContainerInset = NSSize(width: 0, height: 0)
        composer.isVerticallyResizable = true; composer.isHorizontallyResizable = false
        composer.autoresizingMask = [.width]
        composer.textContainer?.widthTracksTextView = true
        composer.textContainer?.lineFragmentPadding = 0
        composer.delegate = self
        composer.onFocus = { [weak self] focused in self?.composerFocused = focused }
        composer.setAccessibilityLabel("Message à Luciole")
        composerScroll.documentView = composer
        composerScroll.drawsBackground = false; composerScroll.borderType = .noBorder; composerScroll.hasVerticalScroller = false
        composerScroll.translatesAutoresizingMaskIntoConstraints = false
        placeholder.font = Theme.sans(13); placeholder.textColor = Theme.muted; placeholder.translatesAutoresizingMaskIntoConstraints = false
        hint.font = Theme.sans(11.5); hint.textColor = Theme.muted; hint.translatesAutoresizingMaskIntoConstraints = false
        // Envoyer : rond de 28, accent, flèche sur-accent ; 35 % si vide.
        sendIcon.image = .oreeSymbol("arrow.up", size: 13, weight: .bold) { Theme.onAccent }
        sendIcon.translatesAutoresizingMaskIntoConstraints = false
        send.addSubview(sendIcon)
        send.onClick = { [weak self] in self?.sendClicked() }
        send.setAccessibilityElement(true); send.setAccessibilityRole(.button); send.setAccessibilityLabel("Envoyer")
        // Arrêter : pastille de 28, fond texte, « Arrêter » écrit en toutes lettres.
        let stopIcon = NSImageView(image: .oreeSymbol("stop.fill", size: 9, weight: .regular) { Theme.page })
        let stopText = NSTextField(labelWithString: "Arrêter"); stopText.font = Theme.sans(12, .semibold); stopText.textColor = Theme.page
        let stopRow = row([stopIcon, stopText], spacing: 6)
        stopPill.addSubview(stopRow)
        stopPill.onClick = { [weak self] in self?.sendClicked() }
        stopPill.hitSlop = 6                      // la cible d'« Arrêter » déborde de 6 pt : plus facile à atteindre
        composerBox.onClick = { [weak self] in self?.focus() }
        stopPill.setAccessibilityElement(true); stopPill.setAccessibilityRole(.button); stopPill.setAccessibilityLabel("Arrêter")
        stopPill.isHidden = true
        for v in [composerScroll, placeholder, hint, send, stopPill] as [NSView] { composerBox.addSubview(v) }
        composerHeight = composerScroll.heightAnchor.constraint(equalToConstant: 40)
        NSLayoutConstraint.activate([
            composerScroll.topAnchor.constraint(equalTo: composerBox.topAnchor, constant: 8), composerScroll.leadingAnchor.constraint(equalTo: composerBox.leadingAnchor, constant: 12),
            composerScroll.trailingAnchor.constraint(equalTo: composerBox.trailingAnchor, constant: -8), composerHeight,
            placeholder.topAnchor.constraint(equalTo: composerScroll.topAnchor), placeholder.leadingAnchor.constraint(equalTo: composerScroll.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: composerScroll.trailingAnchor),
            hint.leadingAnchor.constraint(equalTo: composerBox.leadingAnchor, constant: 12), hint.centerYAnchor.constraint(equalTo: send.centerYAnchor),
            send.topAnchor.constraint(equalTo: composerScroll.bottomAnchor, constant: 6), send.trailingAnchor.constraint(equalTo: composerBox.trailingAnchor, constant: -8),
            send.bottomAnchor.constraint(equalTo: composerBox.bottomAnchor, constant: -8),
            send.widthAnchor.constraint(equalToConstant: 28), send.heightAnchor.constraint(equalToConstant: 28),
            sendIcon.centerXAnchor.constraint(equalTo: send.centerXAnchor), sendIcon.centerYAnchor.constraint(equalTo: send.centerYAnchor),
            stopPill.trailingAnchor.constraint(equalTo: send.trailingAnchor), stopPill.centerYAnchor.constraint(equalTo: send.centerYAnchor), stopPill.heightAnchor.constraint(equalToConstant: 28),
            stopRow.leadingAnchor.constraint(equalTo: stopPill.leadingAnchor, constant: 10), stopRow.trailingAnchor.constraint(equalTo: stopPill.trailingAnchor, constant: -12), stopRow.centerYAnchor.constraint(equalTo: stopPill.centerYAnchor),
        ])
        note.font = Theme.sans(11.5); note.textColor = Theme.muted; note.alignment = .center
        note.translatesAutoresizingMaskIntoConstraints = false
        note.lineBreakMode = .byTruncatingTail

        handle.translatesAutoresizingMaskIntoConstraints = false
        for v in [header, contextRow, scroll, emptyHost, pinnedHost, composerBox, note, handle] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingAnchor), header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),
            contextRow.topAnchor.constraint(equalTo: header.bottomAnchor), contextRow.leadingAnchor.constraint(equalTo: leadingAnchor), contextRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: contextRow.bottomAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyHost.topAnchor.constraint(equalTo: scroll.topAnchor), emptyHost.leadingAnchor.constraint(equalTo: leadingAnchor), emptyHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyHost.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            pinnedHost.topAnchor.constraint(equalTo: scroll.bottomAnchor), pinnedHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), pinnedHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            composerBox.topAnchor.constraint(equalTo: pinnedHost.bottomAnchor, constant: 8), composerBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), composerBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            note.topAnchor.constraint(equalTo: composerBox.bottomAnchor, constant: 6), note.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), note.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            note.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            handle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -8), handle.widthAnchor.constraint(equalToConstant: 8),
            handle.topAnchor.constraint(equalTo: topAnchor), handle.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: Affichage

    func show(_ screen: Screen) {
        canAsk = screen.composerEnabled; running = screen.running
        mascot.apply(screen.pose)
        // Puce d'état
        chipLabel.stringValue = screen.chipText
        chip.setAccessibilityLabel("État : \(screen.chipText)")
        switch screen.chipDot {
        case .accent: chipDot.fill = Theme.accent; chipDot.border = nil
        case .outline: chipDot.fill = nil; chipDot.border = Theme.muted; chipDot.borderWidth = 1.2
        case .alert: chipDot.fill = Theme.hue(.brique); chipDot.border = nil
        case .muted: chipDot.fill = Theme.muted; chipDot.border = nil
        }
        // Puce de contexte
        contextLabel.stringValue = screen.contextText
        contextLabel.textColor = screen.contextShared && !screen.contextLocked ? Theme.text : Theme.muted
        contextPill.setAccessibilityLabel(screen.contextText)
        if let letter = screen.contextLetter, screen.contextShared, !screen.contextLocked {
            contextBadge.isHidden = false; contextIcon.isHidden = true
            contextBadge.configureFavicon(host: letter, fallbackText: letter)
        } else {
            contextBadge.isHidden = true; contextIcon.isHidden = false
            contextIcon.image = .oreeSymbol(screen.contextLocked ? "lock" : "eye.slash", size: 13, weight: .regular) { Theme.muted }
        }
        eyeButton.symbol = screen.contextShared ? "eye" : "eye.slash"
        eyeButton.toolTip = screen.contextShared ? "Ne pas partager cette page" : "Partager cette page"
        eyeButton.setAccessibilityLabel(screen.contextShared ? "Ne pas partager cette page" : "Partager cette page")
        eyeButton.isEnabled = !screen.contextLocked
        // Corps
        rebuildBody(screen)
        // Composeur
        placeholder.stringValue = screen.placeholder
        note.stringValue = screen.note
        composer.isEditable = screen.composerEnabled && !screen.running
        composerBox.alphaValue = screen.composerEnabled || screen.running ? 1 : 0.7
        stopPill.isHidden = !(screen.running && screen.showsStop)
        send.isHidden = screen.running && screen.showsStop
        hint.isHidden = screen.running && screen.showsStop
        updateRing()
        updateSendState()
        placeholder.isHidden = !composer.string.isEmpty
    }

    private func rebuildBody(_ screen: Screen) {
        emptyStack.arrangedSubviews.forEach { emptyStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        switch screen.mode {
        case .conversation:
            scroll.isHidden = false; emptyHost.isHidden = true
        case .empty(let titleText, let sub, let suggestions):
            scroll.isHidden = true; emptyHost.isHidden = false
            let big = LucioleView(size: 64); big.apply(screen.pose)
            emptyStack.addArrangedSubview(big)
            let heading = serif(titleText, size: 28, lineHeight: 1.05)
            let phrase = text(sub, size: 13, color: Theme.muted, lineHeight: 1.55)
            emptyStack.addArrangedSubview(heading); emptyStack.addArrangedSubview(phrase)
            emptyStack.setCustomSpacing(10, after: heading)
            let list = column([], spacing: 6)
            for suggestion in suggestions {
                let card = suggestionCard(suggestion.symbol, suggestion.label, web: suggestion.web) { [weak self] in self?.fill(suggestion.fill) }
                list.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            if !suggestions.isEmpty { emptyStack.addArrangedSubview(list); list.widthAnchor.constraint(equalTo: emptyStack.widthAnchor).isActive = true }
            for v in [heading, phrase] as [NSView] { v.widthAnchor.constraint(equalTo: emptyStack.widthAnchor).isActive = true }
        case .model(let model):
            scroll.isHidden = true; emptyHost.isHidden = false
            let big = LucioleView(size: 80); big.apply(screen.pose)
            emptyStack.addArrangedSubview(big)
            let heading = serif(model.title, size: 26, lineHeight: 1.08)
            let phrase = text(model.text, size: 13, color: Theme.muted, lineHeight: 1.55)
            emptyStack.addArrangedSubview(heading); emptyStack.addArrangedSubview(phrase)
            emptyStack.setCustomSpacing(10, after: heading)
            var wide: [NSView] = [heading, phrase]
            if !model.facts.isEmpty {
                let facts = column([rule()], spacing: 10)
                for fact in model.facts {
                    let label = NSMutableAttributedString(string: fact.bold, attributes: [.font: Theme.sans(13, .semibold), .foregroundColor: Theme.text])
                    label.append(NSAttributedString(string: fact.rest, attributes: [.font: Theme.sans(13), .foregroundColor: Theme.text]))
                    let field = NSTextField(wrappingLabelWithString: ""); field.attributedStringValue = label; field.maximumNumberOfLines = 0
                    field.translatesAutoresizingMaskIntoConstraints = false
                    let line = row([symbol(fact.symbol, size: 14) { Theme.muted }, field], spacing: 10, alignment: .firstBaseline)
                    facts.addArrangedSubview(line); line.widthAnchor.constraint(equalTo: facts.widthAnchor).isActive = true
                }
                let end = rule(); facts.addArrangedSubview(end); end.widthAnchor.constraint(equalTo: facts.widthAnchor).isActive = true
                facts.arrangedSubviews.first?.widthAnchor.constraint(equalTo: facts.widthAnchor).isActive = true
                emptyStack.addArrangedSubview(facts); wide.append(facts)
            }
            if model.progress != nil || model.indeterminate {
                let bar = progressBar(model.progress)
                let left = text(model.progressLeft, size: 12, color: Theme.muted, lines: 1), right = text(model.progressRight, size: 12, color: Theme.muted, lines: 1)
                for l in [left, right] { l.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular) }
                let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                let legend = row([left, spacer, right], spacing: 8)
                let block = column([bar, legend], spacing: 8)
                bar.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
                legend.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
                emptyStack.addArrangedSubview(block); wide.append(block)
            }
            if let primary = model.primary {
                let button = TextButton(primary.title, style: .primary, height: 32) { [weak self] in self?.onModelAction?(primary.action) }
                emptyStack.addArrangedSubview(button); wide.append(button)
            }
            if let secondary = model.secondary {
                let button = TextButton(secondary.title, style: .ghost, height: 28) { [weak self] in self?.onModelAction?(secondary.action) }
                emptyStack.addArrangedSubview(button); wide.append(button)
            }
            if let footnote = model.footnote {
                let note = text(footnote, size: 12, color: Theme.muted, lineHeight: 1.45)
                emptyStack.addArrangedSubview(note); wide.append(note)
            }
            for v in wide { v.widthAnchor.constraint(equalTo: emptyStack.widthAnchor).isActive = true }
        }
    }

    private func progressBar(_ fraction: Double?) -> NSView {
        let track = SurfaceView(fill: Theme.hover, cornerRadius: 3)
        track.heightAnchor.constraint(equalToConstant: 6).isActive = true
        let fill = SurfaceView(fill: Theme.accent, cornerRadius: 3)
        track.addSubview(fill)
        let width = fraction ?? 0.3
        NSLayoutConstraint.activate([
            fill.topAnchor.constraint(equalTo: track.topAnchor), fill.bottomAnchor.constraint(equalTo: track.bottomAnchor), fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: max(CGFloat(width), 0.02)),
        ])
        track.setAccessibilityElement(true); track.setAccessibilityRole(.progressIndicator)
        track.setAccessibilityLabel(fraction.map { "Téléchargement : \(Int($0 * 100)) %" } ?? "En cours")
        if fraction == nil, !Motion.reduced {                       // barre indéterminée : un segment qui va et vient
            let slide = CABasicAnimation(keyPath: "position.x"); slide.fromValue = 0; slide.toValue = 160; slide.duration = 1.2
            slide.autoreverses = true; slide.repeatCount = .infinity; slide.timingFunction = Motion.timing
            fill.wantsLayer = true; fill.layer?.add(slide, forKey: "slide")
        }
        return track
    }

    private func suggestionCard(_ symbolName: String, _ label: String, web: Bool, action: @escaping () -> Void) -> NSView {
        let card = ClickableSurface(fill: Theme.raised, cornerRadius: 10)
        card.elevation = .one
        card.onClick = action
        let icon = symbol(symbolName, size: 14) { Theme.accentInk }
        let field = text(label, size: 13, lineHeight: 1.3); field.isSelectable = false
        var views: [NSView] = [icon, field]
        if web { let tag = text("Web", size: 11.5, color: Theme.muted, lines: 1); tag.isSelectable = false; views.append(tag) }
        let content = row(views, spacing: 10)
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12), content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 9), content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -9),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
        card.setAccessibilityElement(true); card.setAccessibilityRole(.button); card.setAccessibilityLabel(label)
        return card
    }

    // MARK: Le fil

    private var lastSignature = ""
    private var lastPinnedSince: Date?

    /// Empreinte de ce que le fil montre : on ne reconstruit pas les vues (donc on ne perd ni le clic en cours, ni le curseur, ni la sélection) quand rien n'a changé.
    private func signature(_ messages: [AIMessage], writing: Bool, pending: AIPending?) -> String {
        var parts = ["w\(writing)", "e\(expandedTraces.sorted())", "c\(collapsedTraces.sorted())"]
        for m in messages { parts.append("\(m.role)|\(m.text)|\(m.thinking)|\(m.title)|\(m.capped)|\(m.stoppedAtStep ?? -1)|\(m.sources)|" + m.trace.map { "\($0.state)\($0.text)\($0.detail ?? "")" }.joined(separator: ";")) }
        if let pending { parts.append("p\(pending.kind)\(pending.since.timeIntervalSince1970)\(pending.armed)") }
        return parts.joined(separator: "\n")
    }

    func setTranscript(_ messages: [AIMessage], writing: Bool, pending: AIPending?) {
        let sig = signature(messages, writing: writing, pending: pending)
        guard sig != lastSignature else { return }
        lastSignature = sig
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (index, message) in messages.enumerated() {
            let isLast = index == messages.count - 1
            switch message.role {
            case .user: fullWidth(userBubble(message.text), in: stack)
            case .assistant: fullWidth(assistantBlock(message, index: index, live: isLast && writing, pending: isLast ? pending : nil), in: stack)
            }
        }
        if let pending, case .question(let question) = pending.kind { fullWidth(questionCard(question), in: stack) }
        setPinned(pending)
        document.layoutSubtreeIfNeeded()
        let overflow = document.bounds.height - scroll.contentView.bounds.height
        if overflow > 0 { scroll.contentView.scroll(to: NSPoint(x: 0, y: overflow)); scroll.reflectScrolledClipView(scroll.contentView) }
        if case .question = pending?.kind, lastPinnedSince != pending?.since { lastPinnedSince = pending?.since; window?.makeFirstResponder(questionField) }       // le curseur va dans la réponse une seule fois
        else if pending == nil { lastPinnedSince = nil }
    }

    /// Message de la personne : à droite, largeur max 86 %, fond champ, rayon 10, marges 8 / 12, 13 / 1,5.
    private func userBubble(_ string: String) -> NSView {
        let wrapper = NSView(); wrapper.translatesAutoresizingMaskIntoConstraints = false
        let bubble = SurfaceView(fill: Theme.field, cornerRadius: 10)
        let label = text(string, size: 13, lineHeight: 1.5)
        bubble.addSubview(label); wrapper.addSubview(bubble)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8), label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12), label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
            bubble.topAnchor.constraint(equalTo: wrapper.topAnchor), bubble.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            bubble.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor), bubble.leadingAnchor.constraint(greaterThanOrEqualTo: wrapper.leadingAnchor),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: wrapper.widthAnchor, multiplier: 0.86),
        ])
        wrapper.setAccessibilityElement(true); wrapper.setAccessibilityLabel("Vous : \(string)")
        return wrapper
    }

    /// Réponse de Luciole : pas de bulle. En-tête (Luciole 18 + « Luciole » 12 / 600), trace, texte 13 / 1,6, repère d'écriture, sources, actions.
    private func assistantBlock(_ message: AIMessage, index: Int, live: Bool, pending: AIPending?) -> NSView {
        let small = LucioleView(size: 18)
        small.apply(live ? (pending == nil ? .write : .wait) : (message.capped ? .err : .idle))
        let name = NSTextField(labelWithString: "Luciole"); name.font = Theme.sans(12, .semibold); name.textColor = Theme.muted
        var parts: [NSView] = [row([small, name], spacing: 6)]
        if !message.trace.isEmpty {
            let onlySearches = message.trace.allSatisfy { $0.text.hasPrefix("Recherche") }
            if onlySearches { for item in message.trace { parts.append(searchLine(item)) } }
            else { parts.append(traceCard(message, index: index, live: live, pending: pending)) }
        }
        var body: NSView?
        if message.text.isEmpty, live, !message.thinking.isEmpty, pending == nil {
            body = text("Réfléchit… " + String(message.thinking.suffix(260)), size: 12, color: Theme.muted, lineHeight: 1.4)
        } else if message.text.isEmpty, live, message.trace.isEmpty, pending == nil { body = typingCaret() }
        else if !message.text.isEmpty { body = answerText(message.text, caret: live) }
        if let body { parts.append(body) }
        if !message.sources.isEmpty { parts.append(sourcesList(message.sources)) }
        if !message.text.isEmpty, !live { parts.append(actionsRow(message)) }
        let block = column(parts, spacing: 8)
        for part in parts.dropFirst() where !(part is SurfaceView && part.frame.width == 0 && body === part && message.text.isEmpty) { part.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = body !== part || !message.text.isEmpty }
        return block
    }

    private func answerText(_ string: String, caret: Bool) -> NSView {
        let label = text(string, size: 13, lineHeight: 1.6)
        let rendered = NSMutableAttributedString(attributedString: MarkdownRenderer.attributed(caret ? string + " ▍" : string))
        label.attributedStringValue = rendered
        return label
    }

    /// Repère d'écriture : 2 × 15, accent, rayon 1, clignote 1 s (fixe en animations réduites).
    private func typingCaret() -> NSView {
        let caret = SurfaceView(fill: Theme.accent, cornerRadius: 1)
        caret.widthAnchor.constraint(equalToConstant: 2).isActive = true
        caret.heightAnchor.constraint(equalToConstant: 15).isActive = true
        if !Motion.reduced {
            caret.wantsLayer = true
            let blink = CAKeyframeAnimation(keyPath: "opacity"); blink.values = [1, 1, 0, 0, 1]; blink.keyTimes = [0, 0.5, 0.51, 0.99, 1]; blink.duration = 1; blink.repeatCount = .infinity
            caret.layer?.add(blink, forKey: "blink")
        }
        return caret
    }

    private func searchLine(_ item: AgentTraceItem) -> NSView {
        let icon: NSView
        if item.state == .running {
            let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.controlSize = .small; spinner.isIndeterminate = true
            spinner.translatesAutoresizingMaskIntoConstraints = false; spinner.widthAnchor.constraint(equalToConstant: 12).isActive = true; spinner.heightAnchor.constraint(equalToConstant: 12).isActive = true
            if !Motion.reduced { spinner.startAnimation(nil) }
            icon = spinner
        } else { icon = symbol("globe", size: 12) { Theme.muted } }
        let label = text(item.text + (item.detail.map { " · " + $0.replacingOccurrences(of: "Recherche : ", with: "") } ?? ""), size: 12, color: Theme.muted, lines: 2, lineHeight: 1.3)
        return row([icon, label], spacing: 6, alignment: .firstBaseline)
    }

    /// La trace d'actions : surface + ombre-1, rayon 10 ; en-tête de 40 repliable, une ligne par action (numéro serif, rond d'état, titre et détail).
    private func traceCard(_ message: AIMessage, index: Int, live: Bool, pending: AIPending?) -> NSView {
        let collapsed: Bool = live ? collapsedTraces.contains(index) : !expandedTraces.contains(index)
        let card = SurfaceView(fill: Theme.raised, cornerRadius: 10); card.elevation = .one
        let chevron = symbol(collapsed ? "chevron.right" : "chevron.down", size: 11) { Theme.muted }
        let titleLabel = NSTextField(labelWithString: message.title.isEmpty ? "Actions de Luciole" : message.title)
        titleLabel.font = Theme.sans(13, .semibold); titleLabel.textColor = Theme.text; titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Puce : en cours (accent-doux), en attente (accent plein), finie (survol).
        let waiting = live && pending != nil
        let step = message.trace.count
        let chipText: String, chipFill: NSColor, chipInk: NSColor
        if waiting { chipText = "En attente de vous"; chipFill = Theme.accent; chipInk = Theme.onAccent }
        else if live { chipText = "En cours · étape \(step)"; chipFill = Theme.accentSoft; chipInk = Theme.accentInk }
        else if message.capped { chipText = "\(step) étapes · plafond"; chipFill = Theme.hover; chipInk = Theme.muted }
        else if let stopped = message.stoppedAtStep { chipText = "Arrêtée · étape \(stopped)"; chipFill = Theme.hover; chipInk = Theme.muted }
        else { chipText = "\(step) étape\(step > 1 ? "s" : "")"; chipFill = Theme.hover; chipInk = Theme.muted }
        let chipView = SurfaceView(fill: chipFill, cornerRadius: Theme.pill)
        let chipText2 = NSTextField(labelWithString: chipText); chipText2.font = Theme.sans(11.5, .semibold); chipText2.textColor = chipInk
        chipText2.translatesAutoresizingMaskIntoConstraints = false
        chipView.addSubview(chipText2)
        NSLayoutConstraint.activate([
            chipText2.leadingAnchor.constraint(equalTo: chipView.leadingAnchor, constant: 9), chipText2.trailingAnchor.constraint(equalTo: chipView.trailingAnchor, constant: -9),
            chipText2.centerYAnchor.constraint(equalTo: chipView.centerYAnchor), chipView.heightAnchor.constraint(equalToConstant: 22),
        ])
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = ClickableSurface(fill: nil, cornerRadius: 10)
        let headerRow = row([chevron, titleLabel, spacer, chipView], spacing: 8)
        header.addSubview(headerRow)
        NSLayoutConstraint.activate([
            headerRow.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12), headerRow.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            headerRow.centerYAnchor.constraint(equalTo: header.centerYAnchor), header.heightAnchor.constraint(equalToConstant: 40),
        ])
        header.onClick = { [weak self] in
            guard let self else { return }
            if live { if self.collapsedTraces.contains(index) { self.collapsedTraces.remove(index) } else { self.collapsedTraces.insert(index) } }
            else if self.expandedTraces.contains(index) { self.expandedTraces.remove(index) } else { self.expandedTraces.insert(index) }
            self.onRefresh?()
        }
        header.setAccessibilityElement(true); header.setAccessibilityRole(.button)
        header.setAccessibilityLabel("\(titleLabel.stringValue), \(chipText). \(collapsed ? "Déplier" : "Replier")")
        var rows: [NSView] = [header]
        if !collapsed {
            for (n, item) in message.trace.enumerated() {
                let isWaiting = waiting && n == message.trace.count - 1
                rows.append(rule()); rows.append(traceRow(item, number: n + 1, waiting: isWaiting))
            }
        }
        let content = column(rows, spacing: 0)
        card.addSubview(content)
        NSLayoutConstraint.activate([content.topAnchor.constraint(equalTo: card.topAnchor), content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
                                     content.leadingAnchor.constraint(equalTo: card.leadingAnchor), content.trailingAnchor.constraint(equalTo: card.trailingAnchor)])
        for r in rows { r.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        return card
    }

    private func traceRow(_ item: AgentTraceItem, number: Int, waiting: Bool) -> NSView {
        let num = NSTextField(labelWithString: "\(number)")
        num.font = Theme.serifItalic(16); num.textColor = Theme.muted; num.alignment = .right
        num.translatesAutoresizingMaskIntoConstraints = false
        num.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let state = stateCircle(waiting ? .waiting : item.state == .running ? .running : item.state == .done ? .done : .failed)
        // Fait : le résumé lisible (« Saisie dans « Nom ». »). En cours ou échoué : l'action, et la raison dessous.
        let human = item.state == .done ? (item.detail ?? item.text) : item.text
        let title = text(human, size: 12.5, weight: .semibold, lines: 2, lineHeight: 1.3)
        var lines: [NSView] = [title]
        if item.state == .failed, let detail = item.detail, !detail.isEmpty { lines.append(text(detail, size: 12, color: Theme.muted, lines: 2, lineHeight: 1.3)) }
        let textColumn = column(lines, spacing: 1)
        let line = row([num, state, textColumn], spacing: 8, alignment: .top)
        let container = NSView(); container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12), line.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            line.topAnchor.constraint(equalTo: container.topAnchor, constant: 7), line.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -7),
        ])
        container.setAccessibilityElement(true)
        container.setAccessibilityLabel("Étape \(number) : \(item.text). \(item.state == .done ? "Faite" : item.state == .failed ? "Échouée" : waiting ? "En attente de vous" : "En cours"). \(item.detail ?? "")")
        return container
    }

    private enum Circle { case running, done, waiting, failed }
    /// Rond d'état de 18 : en cours (indicateur), faite (coche accent-encre sur accent-doux), attente (accent plein), échouée (contour alerte + croix).
    private func stateCircle(_ kind: Circle) -> NSView {
        let view = SurfaceView(fill: nil, cornerRadius: 9)
        NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: 18), view.heightAnchor.constraint(equalToConstant: 18)])
        var glyph: NSImageView?
        switch kind {
        case .running:
            let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.controlSize = .small; spinner.isIndeterminate = true
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.widthAnchor.constraint(equalToConstant: 14).isActive = true; spinner.heightAnchor.constraint(equalToConstant: 14).isActive = true
            if !Motion.reduced { spinner.startAnimation(nil) }
            view.addSubview(spinner); spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true; spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor).isActive = true
        case .done: view.fill = Theme.accentSoft; glyph = symbol("checkmark", size: 9) { Theme.accentInk }
        case .waiting: view.fill = Theme.accent; glyph = symbol("questionmark", size: 9) { Theme.onAccent }
        case .failed: view.border = Theme.hue(.brique); view.borderWidth = 1.5; glyph = symbol("xmark", size: 8) { Theme.hue(.brique) }
        }
        if let glyph { view.addSubview(glyph); glyph.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true; glyph.centerYAnchor.constraint(equalTo: view.centerYAnchor).isActive = true }
        return view
    }

    /// Sources : lignes de 30, surface + ombre-1, rayon 6 ; numéro serif accent-encre, domaine 12 / 600.
    private func sourcesList(_ urls: [String]) -> NSView {
        var views: [NSView] = []
        for (n, string) in urls.prefix(4).enumerated() {
            guard let url = URL(string: string) else { continue }
            let rowView = ClickableSurface(fill: Theme.raised, cornerRadius: 6); rowView.elevation = .one
            let num = NSTextField(labelWithString: "\(n + 1)"); num.font = Theme.serifItalic(15); num.textColor = Theme.accentInk; num.translatesAutoresizingMaskIntoConstraints = false
            let domain = NSTextField(labelWithString: (url.host ?? string).replacingOccurrences(of: "www.", with: "")); domain.font = Theme.sans(12, .semibold); domain.textColor = Theme.text
            let path = NSTextField(labelWithString: url.path.isEmpty || url.path == "/" ? "" : url.path); path.font = Theme.sans(12); path.textColor = Theme.muted; path.lineBreakMode = .byTruncatingTail
            path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let content = row([num, domain, path], spacing: 8)
            rowView.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 10), content.trailingAnchor.constraint(lessThanOrEqualTo: rowView.trailingAnchor, constant: -10),
                content.centerYAnchor.constraint(equalTo: rowView.centerYAnchor), rowView.heightAnchor.constraint(equalToConstant: 30),
            ])
            rowView.onClick = { [weak self] in self?.onOpenSource?(url) }
            rowView.toolTip = string
            rowView.setAccessibilityElement(true); rowView.setAccessibilityRole(.link); rowView.setAccessibilityLabel("Source \(n + 1) : \(url.host ?? string)")
            views.append(rowView)
        }
        let list = column(views, spacing: 6)
        for v in views { v.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        return list
    }

    /// Actions : puce « D'après cette page » (quand la page était lue) et « Copier » discret (28), qui devient « Copié » 1,5 s.
    private func actionsRow(_ message: AIMessage) -> NSView {
        var views: [NSView] = []
        if message.trace.contains(where: { $0.text.hasPrefix("Lecture") }) || message.sources.isEmpty == false {
            let chipView = SurfaceView(fill: Theme.hover, cornerRadius: Theme.pill)
            let label = NSTextField(labelWithString: message.sources.isEmpty ? "D'après cette page" : "D'après le web"); label.font = Theme.sans(11.5, .medium); label.textColor = Theme.muted
            label.translatesAutoresizingMaskIntoConstraints = false
            chipView.addSubview(label)
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: chipView.leadingAnchor, constant: 9), label.trailingAnchor.constraint(equalTo: chipView.trailingAnchor, constant: -9),
                                         label.centerYAnchor.constraint(equalTo: chipView.centerYAnchor), chipView.heightAnchor.constraint(equalToConstant: 22)])
            views.append(chipView)
        }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views.append(spacer)
        if MarkdownRenderer.deservesAPage(message.text) {
            let page = CopyButton(title: "Ouvrir en page", symbol: "doc.richtext", width: 118, label: "Ouvrir la réponse en page", flash: false)
            page.onClick = { [weak self] in self?.onOpenPage?(message.text) }
            views.append(page)
        }
        let copy = CopyButton(); copy.onClick = { [weak self] in self?.onCopy?(message.text) }
        views.append(copy)
        return row(views, spacing: 8)
    }

    // MARK: Cartes

    /// La carte « Validation requise », épinglée au-dessus du composeur : surface, rayon 14, anneau 2 accent + ombre-3, entrée 260 ms.
    private func setPinned(_ pending: AIPending?) {
        pinnedHost.subviews.forEach { $0.removeFromSuperview() }
        guard let pending, case .confirm(let request) = pending.kind else { pinnedHeight.constant = 0; return }
        let card = ConfirmCardView(fill: Theme.raised, cornerRadius: 14)
        card.border = Theme.accent; card.borderWidth = 2; card.elevation = .three
        card.onCancel = { [weak self] in self?.onConfirm?(false) }
        let small = LucioleView(size: 24); small.apply(.wait)
        let head = NSTextField(labelWithString: "Validation requise"); head.font = Theme.sans(12, .semibold); head.textColor = Theme.accentInk
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let badge = LetterBadgeView(size: 16, cornerRadius: 4); badge.configureFavicon(host: request.host, fallbackText: request.host)
        let host = NSTextField(labelWithString: request.host); host.font = Theme.sans(12); host.textColor = Theme.muted; host.lineBreakMode = .byTruncatingMiddle
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let top = row([small, head, spacer, badge, host], spacing: 6)
        let titleLabel = text(request.title, size: 15, weight: .semibold, lineHeight: 1.25)
        var parts: [NSView] = [top, titleLabel]
        if !request.rows.isEmpty {
            let list = column([], spacing: 0)
            for (key, value) in request.rows {
                let k = NSTextField(labelWithString: key); k.font = Theme.sans(12.5); k.textColor = Theme.muted; k.lineBreakMode = .byTruncatingTail
                k.translatesAutoresizingMaskIntoConstraints = false; k.widthAnchor.constraint(equalToConstant: 96).isActive = true
                let v = text(value, size: 12.5, weight: .medium, lineHeight: 1.3)
                let line = row([k, v], spacing: 10, alignment: .firstBaseline)
                let container = NSView(); container.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(line)
                NSLayoutConstraint.activate([line.leadingAnchor.constraint(equalTo: container.leadingAnchor), line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                                             line.topAnchor.constraint(equalTo: container.topAnchor, constant: 7), line.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -7)])
                let r = rule(); list.addArrangedSubview(r); r.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
                list.addArrangedSubview(container); container.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            let end = rule(); list.addArrangedSubview(end); end.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            parts.append(list)
        }
        let warnIcon = symbol("exclamationmark.triangle", size: 13) { Theme.muted }
        let warn = text(request.warning, size: 12.5, lineHeight: 1.4)
        let warning = row([warnIcon, warn], spacing: 8, alignment: .firstBaseline)
        parts.append(warning)
        let cancel = TextButton("Annuler", style: .secondary, height: 32) { [weak self] in self?.onConfirm?(false) }
        let ok = ArmedButton("Valider l'envoi", since: pending.since); ok.onClick = { [weak self] in self?.onConfirm?(true) }
        let buttons = NSStackView(views: [cancel, ok]); buttons.distribution = .fillEqually; buttons.spacing = 8; buttons.translatesAutoresizingMaskIntoConstraints = false
        parts.append(buttons)
        let foot = text("Entrée ne valide pas. Le bouton s'active après un instant.", size: 11.5, color: Theme.muted, lineHeight: 1.3)
        parts.append(foot)
        let content = column(parts, spacing: 10)
        card.addSubview(content)
        pinnedHost.addSubview(card)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 14), content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14), content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            card.leadingAnchor.constraint(equalTo: pinnedHost.leadingAnchor), card.trailingAnchor.constraint(equalTo: pinnedHost.trailingAnchor), card.bottomAnchor.constraint(equalTo: pinnedHost.bottomAnchor),
        ])
        for v in parts { v.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        pinnedHost.layoutSubtreeIfNeeded()
        pinnedHeight.isActive = false
        pinnedHeight = pinnedHost.heightAnchor.constraint(equalToConstant: card.fittingSize.height)
        pinnedHeight.isActive = true
        card.setAccessibilityElement(true); card.setAccessibilityRole(.group)
        card.setAccessibilityLabel("Validation requise. \(request.title) \(request.warning)")
        if !Motion.reduced {
            card.wantsLayer = true
            let enter = CABasicAnimation(keyPath: "opacity"); enter.fromValue = 0; enter.toValue = 1; enter.duration = Motion.slow; enter.timingFunction = Motion.timing
            card.layer?.add(enter, forKey: "enter")
        }
        if lastPinnedSince != pending.since { lastPinnedSince = pending.since; window?.makeFirstResponder(card) }       // une seule fois : ne pas voler le clavier à chaque mise à jour
    }

    /// La carte de question : surface, rayon 14, ombre-2, dans le fil sous la trace. Entrée répond ; « Laisser ce champ vide » sort sans répondre.
    private func questionCard(_ question: String) -> NSView {
        let card = SurfaceView(fill: Theme.raised, cornerRadius: 14); card.elevation = .two
        let small = LucioleView(size: 24); small.apply(.ask)
        let head = NSTextField(labelWithString: "J'ai besoin de vous"); head.font = Theme.sans(12, .semibold); head.textColor = Theme.accentInk
        let top = row([small, head], spacing: 6)
        let titleLabel = text(question, size: 14, weight: .semibold, lineHeight: 1.3)
        questionField.placeholderString = "Votre réponse"
        questionField.font = Theme.sans(13); questionField.focusRingType = .none
        questionField.isBordered = false; questionField.drawsBackground = false
        questionField.target = self; questionField.action = #selector(answerSubmitted)
        questionField.translatesAutoresizingMaskIntoConstraints = false
        questionField.setAccessibilityLabel("Réponse à la question de Luciole")
        let fieldBox = SurfaceView(fill: Theme.field, cornerRadius: 6)
        fieldBox.addSubview(questionField)
        NSLayoutConstraint.activate([
            fieldBox.heightAnchor.constraint(equalToConstant: 32),
            questionField.leadingAnchor.constraint(equalTo: fieldBox.leadingAnchor, constant: 10), questionField.trailingAnchor.constraint(equalTo: fieldBox.trailingAnchor, constant: -10),
            questionField.centerYAnchor.constraint(equalTo: fieldBox.centerYAnchor),
        ])
        let reply = TextButton("Répondre", style: .primary, height: 32) { [weak self] in self?.answerSubmitted() }
        let answerRow = row([fieldBox, reply], spacing: 8)
        let skip = TextButton("Laisser ce champ vide", style: .ghost, height: 28) { [weak self] in self?.questionField.stringValue = ""; self?.onAnswer?(nil) }
        let content = column([top, titleLabel, answerRow, skip], spacing: 10)
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 14), content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14), content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        ])
        for v in [titleLabel, answerRow] as [NSView] { v.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        card.setAccessibilityElement(true); card.setAccessibilityRole(.group); card.setAccessibilityLabel("Question de Luciole : \(question)")
        return card
    }

    @objc private func answerSubmitted() {
        let value = questionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        questionField.stringValue = ""
        onAnswer?(value.isEmpty ? nil : value)
    }

    // MARK: Composeur et clavier

    private func updateSendState() {
        let hasText = !composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        send.alphaValue = canAsk && hasText ? 1 : 0.35
    }
    func focus() { window?.makeFirstResponder(composer) }
    func fill(_ string: String) { composer.string = string; textDidChange(Notification(name: NSText.didChangeNotification)); focus() }
    func clearComposer() { composer.string = ""; textDidChange(Notification(name: NSText.didChangeNotification)) }

    private func sendClicked() {
        if running { onStop?(); return }
        let value = composer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if canAsk, !value.isEmpty { onSubmit?(value) }
    }

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !composer.string.isEmpty
        updateSendState()
        guard let layout = composer.layoutManager, let container = composer.textContainer else { return }
        layout.ensureLayout(for: container)
        composerHeight.constant = min(max(layout.usedRect(for: container).height, 40), 120)      // 2 à 5 lignes, puis défilement
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            sendClicked()                  // ⇧Entrée envoie `insertLineBreak:` : le saut de ligne reste libre
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default: return false
        }
    }
}

/// Un bouton fait d'une surface : il prend le clic même quand la fenêtre n'est pas active (premier clic compris), répond au relâché dans ses limites et
/// ne laisse pas ses sous-vues (icône, texte) intercepter le clic. `hitSlop` agrandit la cible de quelques points.
@MainActor
final class PressableSurface: SurfaceView {
    var onClick: (() -> Void)?
    var hitSlop: CGFloat = 0
    private var pressed = false { didSet { alphaValue = pressed ? 0.8 : 1 } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.insetBy(dx: -hitSlop, dy: -hitSlop).contains(local) && !isHidden ? self : nil
    }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.insetBy(dx: -hitSlop, dy: -hitSlop).contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// Le bloc du composeur : un clic n'importe où dans le bloc (marges, ligne d'aide) met le curseur dans le champ.
@MainActor
final class FocusingSurface: SurfaceView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Une surface cliquable (carte de suggestion, en-tête de trace, ligne de source) : survol = fond page, appui = échelle 0,99.
@MainActor
private final class ClickableSurface: SurfaceView {
    var onClick: (() -> Void)?
    private let baseFill: NSColor?
    override init(fill: NSColor? = nil, cornerRadius: CGFloat = 0) {
        baseFill = fill
        super.init(fill: fill, cornerRadius: cornerRadius)
        onHover = { [weak self] inside in
            guard let self else { return }
            self.fill = inside ? (self.baseFill == nil ? Theme.hover : Theme.page) : self.baseFill
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if !Motion.reduced { wantsLayer = true; layer?.setAffineTransform(CGAffineTransform(scaleX: 0.99, y: 0.99)) }
    }
    override func mouseUp(with event: NSEvent) {
        layer?.setAffineTransform(.identity)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// « Copier » discret (28) : devient « Copié » pendant 1,5 s.
@MainActor
private final class CopyButton: HoverView {
    var onClick: (() -> Void)?
    private var copied = false
    private let title: String, symbol: String, width: CGFloat, flash: Bool
    init(title: String = "Copier", symbol: String = "doc.on.doc", width: CGFloat = 74, label: String = "Copier la réponse", flash: Bool = true) {
        self.title = title; self.symbol = symbol; self.width = width; self.flash = flash
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: width, height: 28) }
    override func draw(_ dirtyRect: NSRect) {
        if hover > 0.001 { Theme.hover.scaled(hover).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
        let image = NSImage.oreeSymbol(copied ? "checkmark" : symbol, size: 12, weight: .regular) { Theme.muted }
        image.draw(in: NSRect(x: 8, y: bounds.midY - 7, width: 14, height: 14))
        let text = NSAttributedString(string: copied ? "Copié" : title, attributes: [.font: Theme.sans(12, .medium), .foregroundColor: Theme.muted])
        text.draw(at: NSPoint(x: 28, y: bounds.midY - text.size().height / 2))
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        onClick?()
        guard flash else { return }
        copied = true; needsDisplay = true
        Task { try? await Task.sleep(for: .seconds(1.5)); self.copied = false; self.needsDisplay = true }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
