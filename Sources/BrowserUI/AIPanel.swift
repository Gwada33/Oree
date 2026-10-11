import AppKit
import BrowserCore
import DownloadKit
import OreeAIClient
import OreeAIEngine
import OreeAIProtocol
import BrowserStorage
import WebKit

/// Un message de la conversation d'un onglet. Une réponse de l'IA porte la trace des actions faites pour la produire, et ses sources.
struct AIMessage {
    enum Role { case user, assistant }
    var role: Role
    var text: String
    var trace: [AgentTraceItem] = []
    var sources: [String] = []
}

/// Ce que le fil affiche en plus des messages : une action à valider, ou une question de l'IA, ou rien.
struct AIPending: Equatable {
    enum Kind: Equatable { case confirm(String), question(String) }
    var kind: Kind
    var since: Date
    /// « Valider » ne répond qu'après 0,8 s : impossible à valider d'un clic réflexe.
    var armed: Bool { Date().timeIntervalSince(since) >= 0.8 }
}

/// La poignée du bord gauche du panneau : on la tire pour changer sa largeur (320 à 520 pt), comme la barre latérale gauche.
@MainActor
private final class PanelHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?       // largeur voulue
    var onEnd: (() -> Void)?
    var currentWidth: () -> CGFloat = { 380 }
    private var startX: CGFloat = 0, startWidth: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Largeur du panneau IA")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { startX = NSEvent.mouseLocation.x; startWidth = currentWidth() }
    override func mouseDragged(with event: NSEvent) { onDrag?(startWidth + (startX - NSEvent.mouseLocation.x)) }
    override func mouseUp(with event: NSEvent) { onEnd?() }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Le panneau IA : une colonne collée au bord droit de la fenêtre. Il ne décide de rien : il montre ce que `AIPanelController` lui donne.
@MainActor
final class AIPanelView: SurfaceView, NSTextViewDelegate {
    // En-tête
    let mascot = LucioleView(size: 28)
    private let title = oreeLabel("Luciole", font: Theme.serifItalic(19), color: Theme.text)
    private let chip = oreeLabel("", font: Theme.sans(11.5, .medium), color: Theme.muted)
    private let newChat = ChromeIconButton(symbol: "square.and.pencil", label: "Nouvelle conversation", size: 28, pointSize: 13)
    private let closeButton = ChromeIconButton(symbol: "xmark", label: "Fermer le panneau", size: 28, pointSize: 12)
    private let context = oreeLabel("", font: Theme.sans(12), color: Theme.muted)
    private let contextBox = SurfaceView(fill: Theme.hover, cornerRadius: Theme.pill)
    // Corps
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let stack = NSStackView()
    private let emptyState = NSView()
    private let bigMascot = LucioleView(size: 64)
    private let emptyTitle = oreeLabel("", font: Theme.serifItalic(26), color: Theme.text, lines: 0)
    private let emptyText = oreeLabel("", font: Theme.sans(13), color: Theme.muted, lines: 0)
    private let progress = NSProgressIndicator()
    private let download = TextButton("Télécharger le modèle", style: .primary)
    private let suggestions = NSStackView()
    private let questionField = NSTextField()
    private var expandedTraces: Set<Int> = []
    // Composeur
    private let composer = NSTextView()
    private let composerScroll = NSScrollView()
    private let placeholder = oreeLabel("", font: Theme.sans(13), color: Theme.muted)
    private let send = ChromeIconButton(symbol: "arrow.up", label: "Envoyer", size: 28, pointSize: 13)
    private let note = oreeLabel("Tout reste sur ce Mac · l'IA peut se tromper", font: Theme.sans(11), color: Theme.muted)
    private var composerHeight: NSLayoutConstraint!
    private let handle = PanelHandle()

    private var running = false
    private var canAsk = false

    var onSubmit: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onDownload: (() -> Void)?
    var onClose: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onToggleShare: (() -> Void)?
    var onConfirm: ((Bool) -> Void)?
    var onAnswer: ((String?) -> Void)?
    var onCopy: ((String) -> Void)?
    var onOpenSource: ((URL) -> Void)?
    var onResize: ((CGFloat) -> Void)? { didSet { handle.onDrag = onResize } }
    var onResizeEnd: (() -> Void)? { didSet { handle.onEnd = onResizeEnd } }
    var currentWidth: () -> CGFloat = { 380 } { didSet { handle.currentWidth = currentWidth } }

    init() {
        super.init(fill: Theme.page)
        setAccessibilityElement(false)
        setAccessibilityLabel("Panneau IA")
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func rule(vertical: Bool = false) -> NSView {
        let line = SurfaceView(fill: Theme.line)
        (vertical ? line.widthAnchor : line.heightAnchor).constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func build() {
        // En-tête : 48 pt, mascotte, titre, état du modèle, nouvelle conversation, fermer.
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        chip.lineBreakMode = .byTruncatingTail
        chip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        newChat.onClick = { [weak self] in self?.onNewChat?() }
        closeButton.onClick = { [weak self] in self?.onClose?() }
        let header = NSStackView(views: [mascot, title, chip, NSView(), newChat, closeButton])
        header.orientation = .horizontal; header.spacing = 8; header.alignment = .centerY
        header.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 12)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.views[3].setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Puce de contexte : ce que l'IA voit. Un clic la coupe ou la rétablit (la page n'est alors pas partagée).
        context.lineBreakMode = .byTruncatingTail
        contextBox.addSubview(context)
        contextBox.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(toggleShare)))
        contextBox.setAccessibilityElement(true)
        contextBox.setAccessibilityRole(.button)
        contextBox.toolTip = "Partager ou non la page avec l'IA"
        NSLayoutConstraint.activate([
            context.leadingAnchor.constraint(equalTo: contextBox.leadingAnchor, constant: 10), context.trailingAnchor.constraint(equalTo: contextBox.trailingAnchor, constant: -10),
            context.centerYAnchor.constraint(equalTo: contextBox.centerYAnchor), contextBox.heightAnchor.constraint(equalToConstant: 24),
        ])

        // Fil de conversation : une pile verticale (messages, trace, cartes) dans un défilement.
        stack.orientation = .vertical; stack.spacing = 16; stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 14), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
        ])

        // État vide / états du modèle (même emplacement)
        progress.style = .bar; progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.setAccessibilityLabel("Progression du téléchargement")
        download.onClick = { [weak self] in self?.onDownload?() }
        suggestions.orientation = .vertical; suggestions.spacing = 6; suggestions.alignment = .leading
        let stateStack = NSStackView(views: [bigMascot, emptyTitle, emptyText, progress, download, suggestions])
        stateStack.orientation = .vertical; stateStack.spacing = 12; stateStack.alignment = .leading
        stateStack.setCustomSpacing(16, after: bigMascot)
        stateStack.translatesAutoresizingMaskIntoConstraints = false
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.addSubview(stateStack)
        NSLayoutConstraint.activate([
            stateStack.topAnchor.constraint(equalTo: emptyState.topAnchor, constant: 32),
            stateStack.leadingAnchor.constraint(equalTo: emptyState.leadingAnchor, constant: 24), stateStack.trailingAnchor.constraint(equalTo: emptyState.trailingAnchor, constant: -24),
            progress.widthAnchor.constraint(equalTo: stateStack.widthAnchor),
        ])

        // Composeur : champ multiligne (Entrée envoie, ⇧Entrée = saut de ligne), bouton envoyer / arrêter.
        composer.font = Theme.sans(13); composer.textColor = Theme.text
        composer.drawsBackground = false; composer.isRichText = false; composer.allowsUndo = true
        composer.textContainerInset = NSSize(width: 0, height: 6)
        composer.isVerticallyResizable = true; composer.isHorizontallyResizable = false
        composer.autoresizingMask = [.width]
        composer.textContainer?.widthTracksTextView = true
        composer.delegate = self
        composer.setAccessibilityLabel("Message à Luciole")
        composerScroll.documentView = composer
        composerScroll.drawsBackground = false; composerScroll.borderType = .noBorder; composerScroll.hasVerticalScroller = false
        composerScroll.translatesAutoresizingMaskIntoConstraints = false
        send.onClick = { [weak self] in self?.sendOrStop() }
        let field = SurfaceView(fill: Theme.field, cornerRadius: Theme.radius)
        field.border = Theme.line
        for v in [composerScroll, placeholder, send] as [NSView] { field.addSubview(v) }
        composerHeight = composerScroll.heightAnchor.constraint(equalToConstant: 32)
        NSLayoutConstraint.activate([
            composerScroll.topAnchor.constraint(equalTo: field.topAnchor, constant: 4), composerScroll.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 12),
            composerScroll.trailingAnchor.constraint(equalTo: send.leadingAnchor, constant: -4), composerHeight,
            composerScroll.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -4),
            placeholder.leadingAnchor.constraint(equalTo: composerScroll.leadingAnchor, constant: 5), placeholder.centerYAnchor.constraint(equalTo: composerScroll.topAnchor, constant: 16),
            placeholder.trailingAnchor.constraint(equalTo: composerScroll.trailingAnchor),
            send.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -6), send.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -6),
        ])
        placeholder.isEnabled = false

        let footer = NSStackView(views: [field, note])
        footer.orientation = .vertical; footer.spacing = 8; footer.alignment = .leading
        footer.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        footer.translatesAutoresizingMaskIntoConstraints = false
        field.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16).isActive = true

        let contextRow = NSView(); contextRow.translatesAutoresizingMaskIntoConstraints = false
        contextRow.addSubview(contextBox)
        NSLayoutConstraint.activate([
            contextBox.leadingAnchor.constraint(equalTo: contextRow.leadingAnchor, constant: 16), contextBox.topAnchor.constraint(equalTo: contextRow.topAnchor),
            contextBox.bottomAnchor.constraint(equalTo: contextRow.bottomAnchor, constant: -8),
            contextBox.trailingAnchor.constraint(lessThanOrEqualTo: contextRow.trailingAnchor, constant: -16),
        ])

        let topRule = rule(), bottomRule = rule(), leftRule = rule(vertical: true)
        handle.translatesAutoresizingMaskIntoConstraints = false
        for v in [header, contextRow, topRule, scroll, emptyState, bottomRule, footer, leftRule, handle] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingAnchor), header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 48),
            contextRow.topAnchor.constraint(equalTo: header.bottomAnchor), contextRow.leadingAnchor.constraint(equalTo: leadingAnchor), contextRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            topRule.topAnchor.constraint(equalTo: contextRow.bottomAnchor), topRule.leadingAnchor.constraint(equalTo: leadingAnchor), topRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topRule.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: topRule.bottomAnchor), emptyState.leadingAnchor.constraint(equalTo: leadingAnchor), emptyState.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            bottomRule.topAnchor.constraint(equalTo: scroll.bottomAnchor), bottomRule.leadingAnchor.constraint(equalTo: leadingAnchor), bottomRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.topAnchor.constraint(equalTo: bottomRule.bottomAnchor), footer.leadingAnchor.constraint(equalTo: leadingAnchor), footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftRule.leadingAnchor.constraint(equalTo: leadingAnchor), leftRule.topAnchor.constraint(equalTo: topAnchor), leftRule.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -3), handle.widthAnchor.constraint(equalToConstant: 8),
            handle.topAnchor.constraint(equalTo: topAnchor), handle.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func toggleShare() { onToggleShare?() }

    // MARK: Affichage

    struct Screen {
        var pose: LucioleState
        var chip: String
        var context: String
        var title: String          // état vide / état du modèle
        var text: String
        var progress: Double?      // téléchargement
        var offersDownload: Bool
        var showsEmpty: Bool       // vrai : l'état vide remplace le fil
        var suggestions: [(label: String, fill: String)]
        var canAsk: Bool
        var running: Bool
        var placeholder: String
    }

    func show(_ screen: Screen) {
        canAsk = screen.canAsk; running = screen.running
        mascot.apply(screen.pose); bigMascot.apply(screen.pose)
        chip.stringValue = screen.chip
        context.stringValue = screen.context
        contextBox.setAccessibilityLabel(screen.context)
        emptyTitle.stringValue = screen.title
        emptyText.stringValue = screen.text
        progress.isHidden = screen.progress == nil
        progress.doubleValue = screen.progress ?? 0
        download.isHidden = !screen.offersDownload
        emptyState.isHidden = !screen.showsEmpty
        scroll.isHidden = screen.showsEmpty
        suggestions.arrangedSubviews.forEach { suggestions.removeArrangedSubview($0); $0.removeFromSuperview() }
        if screen.canAsk {
            for suggestion in screen.suggestions {
                let button = TextButton(suggestion.label, style: .secondary)
                button.onClick = { [weak self] in self?.fill(suggestion.fill) }
                suggestions.addArrangedSubview(button)
            }
        }
        placeholder.stringValue = screen.placeholder
        composer.isEditable = screen.canAsk && !screen.running
        send.symbol = screen.running ? "stop.fill" : "arrow.up"
        send.toolTip = screen.running ? "Arrêter" : "Envoyer"
        send.setAccessibilityLabel(screen.running ? "Arrêter" : "Envoyer")
        send.isEnabled = screen.running || (screen.canAsk && !composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        placeholder.isHidden = !composer.string.isEmpty
    }

    // MARK: Le fil

    private func label(_ text: String, font: NSFont, color: NSColor, selectable: Bool = true) -> NSTextField {
        let l = oreeLabel(text, font: font, color: color, lines: 0)
        l.isSelectable = selectable
        return l
    }

    private func author(_ name: String, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.attributedStringValue = NSAttributedString(string: name.uppercased(), attributes: [.font: Theme.sans(10.5, .bold), .foregroundColor: color, .kern: 0.6])
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    /// Une pile de lignes qui prend toute la largeur du fil.
    private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical; s.alignment = .leading; s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    private func addFullWidth(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    func setTranscript(_ messages: [AIMessage], writing: Bool, pending: AIPending?) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (index, message) in messages.enumerated() {
            let isLast = index == messages.count - 1
            switch message.role {
            case .user:
                addFullWidth(column([author("Vous", color: Theme.muted), label(message.text, font: Theme.sans(13.5), color: Theme.text)], spacing: 3))
            case .assistant:
                var parts: [NSView] = []
                if !message.trace.isEmpty { parts.append(traceView(message.trace, index: index, live: isLast && writing)) }
                parts.append(author("Luciole", color: Theme.accentInk))
                if message.text.isEmpty, isLast, writing, pending == nil { parts.append(label("▍", font: Theme.sans(13.5), color: Theme.muted, selectable: false)) }
                else if !message.text.isEmpty { parts.append(label(message.text, font: Theme.sans(13.5), color: Theme.text)) }
                if !message.sources.isEmpty { parts.append(sourcesView(message.sources)) }
                if !message.text.isEmpty, !(isLast && writing) {
                    let copy = TextButton("Copier", style: .ghost)
                    copy.onClick = { [weak self] in self?.onCopy?(message.text) }
                    parts.append(copy)
                }
                addFullWidth(column(parts, spacing: 6))
            }
        }
        if let pending {
            switch pending.kind {
            case .confirm(let summary): addFullWidth(confirmCard(summary, armed: pending.armed))
            case .question(let text): addFullWidth(questionCard(text))
            }
        }
        document.layoutSubtreeIfNeeded()
        let overflow = document.bounds.height - scroll.contentView.bounds.height
        if overflow > 0 { scroll.contentView.scroll(to: NSPoint(x: 0, y: overflow)); scroll.reflectScrolledClipView(scroll.contentView) }
        if case .question = pending?.kind, window?.firstResponder !== questionField.currentEditor() { window?.makeFirstResponder(questionField) }
    }

    /// Une ligne par action, avec son état. Repliée une fois la tâche finie (un clic sur l'en-tête la rouvre).
    private func traceView(_ items: [AgentTraceItem], index: Int, live: Bool) -> NSView {
        let expanded = live || expandedTraces.contains(index)
        let failed = items.filter { $0.state == .failed }.count
        var title = "\(expanded ? "▾" : "▸")  \(items.count) action" + (items.count > 1 ? "s" : "")
        if failed > 0, !live { title += " · \(failed) échouée" + (failed > 1 ? "s" : "") }
        let head = NSTextField(labelWithString: title)
        head.font = Theme.sans(12, .medium); head.textColor = Theme.muted
        head.translatesAutoresizingMaskIntoConstraints = false
        head.setAccessibilityRole(.button)
        head.setAccessibilityLabel("Actions de l'IA : \(items.count)")
        var rows: [NSView] = [head]
        if !live {
            let click = NSClickGestureRecognizer(target: self, action: #selector(traceClicked(_:)))
            head.addGestureRecognizer(click)
            head.identifier = NSUserInterfaceItemIdentifier("\(index)")
        }
        if expanded {
            for item in items {
                let symbol = item.state == .running ? "circle.dotted" : item.state == .done ? "checkmark" : "xmark"
                let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: item.state == .failed ? "Échec" : item.state == .done ? "Fait" : "En cours") ?? NSImage())
                image.contentTintColor = item.state == .failed ? Theme.hueInk(.brique) : item.state == .done ? Theme.accentInk : Theme.muted
                image.translatesAutoresizingMaskIntoConstraints = false
                image.widthAnchor.constraint(equalToConstant: 14).isActive = true
                let text = label(item.text, font: Theme.sans(12), color: Theme.muted)
                let row = NSStackView(views: [image, text])
                row.orientation = .horizontal; row.alignment = .firstBaseline; row.spacing = 6
                row.translatesAutoresizingMaskIntoConstraints = false
                rows.append(row)
            }
        }
        return column(rows, spacing: 4)
    }

    @objc private func traceClicked(_ gesture: NSClickGestureRecognizer) {
        guard let id = gesture.view?.identifier?.rawValue, let index = Int(id) else { return }
        if expandedTraces.contains(index) { expandedTraces.remove(index) } else { expandedTraces.insert(index) }
        onRefresh?()
    }
    var onRefresh: (() -> Void)?

    private func sourcesView(_ urls: [String]) -> NSView {
        var views: [NSView] = [label("Sources", font: Theme.sans(11, .semibold), color: Theme.muted, selectable: false)]
        for string in urls.prefix(4) {
            guard let url = URL(string: string) else { continue }
            let button = NSButton(title: url.host ?? string, target: nil, action: nil)
            button.isBordered = false; button.alignment = .left
            button.contentTintColor = Theme.accentInk
            button.font = Theme.sans(12)
            button.toolTip = string
            button.setAccessibilityLabel("Ouvrir la source \(url.host ?? string)")
            button.target = self
            button.action = #selector(openSource(_:))
            button.cell?.representedObject = url
            views.append(button)
        }
        return column(views, spacing: 2)
    }

    @objc private func openSource(_ sender: NSButton) { if let url = sender.cell?.representedObject as? URL { onOpenSource?(url) } }

    /// La carte « à valider » : impossible à rater (cadre ocre, ombre), impossible à valider d'un geste réflexe (0,8 s, jamais la touche Entrée).
    private func confirmCard(_ summary: String, armed: Bool) -> NSView {
        let card = SurfaceView(fill: Theme.raised, cornerRadius: Theme.radius)
        card.border = Theme.hue(.ocre); card.borderWidth = 1.5; card.elevation = .two
        let heading = author("À valider", color: Theme.hueInk(.ocre))
        let text = label(summary, font: Theme.sans(13.5, .medium), color: Theme.text)
        let hint = label("Rien n'est envoyé tant que vous n'avez pas validé.", font: Theme.sans(11.5), color: Theme.muted)
        let cancel = TextButton("Annuler", style: .secondary) { [weak self] in self?.onConfirm?(false) }
        let ok = TextButton("Valider", style: .primary) { [weak self] in self?.onConfirm?(true) }
        ok.alphaValue = armed ? 1 : 0.4
        if !armed { ok.onClick = nil }
        ok.setAccessibilityLabel(armed ? "Valider" : "Valider (disponible dans un instant)")
        let buttons = NSStackView(views: [cancel, ok]); buttons.spacing = 8
        let content = column([heading, text, hint, buttons], spacing: 8)
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 14), content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14), content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        ])
        card.setAccessibilityElement(true); card.setAccessibilityRole(.group); card.setAccessibilityLabel("Action à valider : \(summary)")
        return card
    }

    private func questionCard(_ question: String) -> NSView {
        let card = SurfaceView(fill: Theme.raised, cornerRadius: Theme.radius)
        card.border = Theme.line
        let heading = author("Luciole demande", color: Theme.accentInk)
        let text = label(question, font: Theme.sans(13.5), color: Theme.text)
        questionField.placeholderString = "Votre réponse"
        questionField.font = Theme.sans(13); questionField.focusRingType = .none
        questionField.isBordered = false; questionField.drawsBackground = true; questionField.backgroundColor = Theme.field
        questionField.target = self; questionField.action = #selector(answerSubmitted)
        questionField.translatesAutoresizingMaskIntoConstraints = false
        questionField.heightAnchor.constraint(equalToConstant: 28).isActive = true
        questionField.setAccessibilityLabel("Réponse à la question de Luciole")
        let reply = TextButton("Répondre", style: .primary) { [weak self] in self?.answerSubmitted() }
        let skip = TextButton("Passer", style: .ghost) { [weak self] in self?.questionField.stringValue = ""; self?.onAnswer?(nil) }
        let buttons = NSStackView(views: [reply, skip]); buttons.spacing = 8
        let content = column([heading, text, questionField, buttons], spacing: 8)
        questionField.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 14), content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14), content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        ])
        return card
    }

    @objc private func answerSubmitted() {
        let text = questionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        questionField.stringValue = ""
        onAnswer?(text.isEmpty ? nil : text)
    }

    var focusedOnQuestion: Bool { questionField.currentEditor() != nil }
    func focus() { window?.makeFirstResponder(composer) }
    func fill(_ text: String) { composer.string = text; textDidChange(Notification(name: NSText.didChangeNotification)); focus() }
    func clearComposer() { composer.string = ""; textDidChange(Notification(name: NSText.didChangeNotification)) }
    var visibleText: String { stack.arrangedSubviews.map { $0.debugDescription }.joined() }

    // MARK: Clavier

    private func sendOrStop() {
        if running { onStop?(); return }
        let text = composer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if canAsk, !text.isEmpty { onSubmit?(text) }
    }

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !composer.string.isEmpty
        send.isEnabled = running || (canAsk && !composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        guard let layout = composer.layoutManager, let container = composer.textContainer else { return }
        layout.ensureLayout(for: container)
        composerHeight.constant = min(max(layout.usedRect(for: container).height + 12, 32), 120)   // 1 à 5 lignes environ
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            sendOrStop()                    // ⇧Entrée envoie `insertLineBreak:` : le saut de ligne reste libre
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default: return false
        }
    }
}

/// Fait le lien entre le panneau, le service IA, la page, la recherche, le téléchargement du modèle et l'agent launchd. Une conversation par onglet.
///
/// Rien ne démarre avant la première ouverture : ni l'agent, ni la connexion au service. Une tâche à la fois (le service refuse la seconde).
/// Chaque question lance la boucle d'agent (`AgentLoop`, BrowserCore) : le modèle voit la page (si elle est partagée), demande un outil, le
/// navigateur le fait (avec confirmation pour tout geste sensible), jusqu'à la réponse ou un plafond (15 étapes, 3 recherches, 5 pages).
/// Le service n'a ni génération contrainte ni appels d'outils natifs (étape 5 du plan) : le modèle écrit une ligne JSON que `AgentParser`
/// lit avec indulgence. Avec un modèle de 2 milliards de paramètres, les actions longues réussiront souvent à moitié : la trace et les
/// confirmations sont là pour que la personne garde la main.
@MainActor
final class AIPanelController {
    struct Hooks {
        var activeWebView: () -> WKWebView?
        var navigate: (String) async -> Bool
        var openTab: (URL) -> Void
        var windowWidth: () -> CGFloat
        var onLayout: (CGFloat) -> Void           // largeur dont la page doit s'écarter (0 : rien)
    }

    private let panel = AIPanelView()
    private let client: AIClient
    private weak var downloads: DownloadsController?
    private let hooks: Hooks
    /// Appelé quand le panneau s'ouvre ou se ferme (le bouton de la barre d'outils suit).
    var onVisibilityChange: ((Bool) -> Void)?
    private let pin = ModelPin.default
    private let machName = ProcessInfo.processInfo.environment["HB_AI_MACH_NAME"] ?? OreeAIServiceInfo.machName
    private var widthConstraint: NSLayoutConstraint!
    private let search = SearchTab()

    private var reachable: Bool?
    private var status: AIStatus?
    private var download: AIDownloadProgress?
    private var downloadID: UUID?
    private var downloadTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var started = false
    private var failure: String?
    private var conversations: [UUID: [AIMessage]] = [:]
    private var currentTab: UUID?
    private var currentTitle = ""
    private var shareContext = true
    // La tâche en cours
    private var agentTask: Task<Void, Never>?
    private var runTab: UUID?
    private var runID = UUID()           // une tâche arrêtée peut finir plus tard : seule la tâche courante met l'affichage à jour
    private var turn: (id: String, buffer: String, continuation: CheckedContinuation<String, Error>)?
    private var pending: AIPending?
    private var cancelling: Task<Void, Never>?    // le service finit d'arrêter l'ancien tour : on attend avant d'en lancer un autre
    private var confirmContinuation: CheckedContinuation<Bool, Never>?
    private var questionContinuation: CheckedContinuation<String?, Never>?

    private static let widthKey = "oree.ai.panelWidth"
    private var width = AIPanelMetrics.clamp((UserDefaults.standard.object(forKey: AIPanelController.widthKey) as? Double) ?? AIPanelMetrics.defaultWidth)

    init(contentView: NSView, top: NSLayoutYAxisAnchor, downloads: DownloadsController, hooks: Hooks) {
        self.downloads = downloads
        self.hooks = hooks
        self.client = AIClient(machService: ProcessInfo.processInfo.environment["HB_AI_MACH_NAME"] ?? OreeAIServiceInfo.machName)
        panel.isHidden = true
        contentView.addSubview(panel)
        widthConstraint = panel.widthAnchor.constraint(equalToConstant: CGFloat(width))
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: top), panel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            panel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor), widthConstraint,
        ])
        panel.onSubmit = { [weak self] text in self?.ask(text) }
        panel.onStop = { [weak self] in self?.stop() }
        panel.onDownload = { [weak self] in self?.downloadModel() }
        panel.onClose = { [weak self] in self?.close() }
        panel.onNewChat = { [weak self] in self?.newConversation() }
        panel.onToggleShare = { [weak self] in self?.shareContext.toggle(); self?.refresh() }
        panel.onConfirm = { [weak self] ok in self?.resolveConfirm(ok) }
        panel.onAnswer = { [weak self] text in self?.resolveQuestion(text) }
        panel.onCopy = { text in NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
        panel.onOpenSource = { [weak self] url in self?.hooks.openTab(url) }
        panel.onRefresh = { [weak self] in self?.refresh() }
        panel.currentWidth = { [weak self] in CGFloat(self?.width ?? 380) }
        panel.onResize = { [weak self] wanted in self?.resize(to: Double(wanted)) }
        panel.onResizeEnd = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(self.width, forKey: Self.widthKey)
        }
        // Les notifications de la fenêtre arrivent sur le fil principal ; on ne passe pas `Notification` (non Sendable) au code isolé.
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dock() }
        }
    }

    var view: NSView { panel }
    var isOpen: Bool { !panel.isHidden }

    private var availability: AIAvailability { AIAvailability(reachable: reachable, status: status, download: download) }
    private var isRunning: Bool { agentTask != nil }
    private var messages: [AIMessage] {
        get { currentTab.flatMap { conversations[$0] } ?? [] }
        set { if let id = currentTab { conversations[id] = newValue } }
    }

    func toggle() { isOpen ? close() : open() }

    func open() {
        panel.isHidden = false
        onVisibilityChange?(true)
        dock()
        panel.focus()
        refresh()
        Task { await prepare() }
    }

    func close() {
        panel.isHidden = true
        onVisibilityChange?(false)
        hooks.onLayout(0)
        panel.window?.makeFirstResponder(nil)
        if isRunning { stop() }
    }

    /// Le panneau pousse la page si la fenêtre est assez large ; sinon il la recouvre.
    private func dock() {
        guard isOpen else { return }
        hooks.onLayout(AIPanelMetrics.pushesPage(windowWidth: Double(hooks.windowWidth())) ? CGFloat(width) : 0)
    }

    private func resize(to wanted: Double) {
        width = AIPanelMetrics.clamp(wanted)
        widthConstraint.constant = CGFloat(width)
        dock()
    }

    // MARK: Onglets

    /// L'onglet actif a changé : sa conversation revient. Le titre sert à la puce de contexte.
    func tabChanged(id: UUID?, title: String?) {
        currentTab = id
        currentTitle = title ?? ""
        refresh()
    }
    func tabClosed(_ id: UUID) { conversations[id] = nil }

    func newConversation() {
        if isRunning { stop() }
        messages = []
        failure = nil
        refresh()
        panel.focus()
    }

    // MARK: Service

    /// Installe l'agent (une fois, sans danger à répéter), vérifie l'état du service puis le réveille pour que la première question parte vite.
    private func prepare() async {
        if !started {
            started = true
            reachable = await ensureAgent() ? nil : false
            if reachable == nil { startListening() }
        }
        refresh()
        guard reachable != false else { return }
        guard let current = await client.status() else { reachable = false; refresh(); return }
        reachable = true
        status = current
        refresh()
        // « Vérification » = fichier présent mais pas encore vérifié : c'est `warmUp` qui lance la vérification (≈ 1 s pour 1,3 Go, une fois par
        // lancement du service) puis réveille le modèle. On le fait dès que le panneau s'ouvre, pour que la première question parte vite.
        if current.model == .ready || current.model == .verifying, let warmed = await client.warmUp(timeout: 40) { status = warmed; refresh() }
    }

    /// L'agent pointe vers l'exécutable `OreeAI` de CETTE copie de l'app. `HB_AI_NO_AGENT=1` : l'agent est géré à la main (essais).
    private func ensureAgent() async -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["HB_AI_NO_AGENT"] != nil { return true }
        guard Bundle.main.bundlePath.hasSuffix(".app"),
              let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("OreeAI") else { return false }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.nolhan.hyperbrowser"
        let name = machName
        // launchctl prend du temps : jamais sur le fil principal.
        let result = await Task.detached { Result { try AIAgentInstaller.ensureInstalled(executable: executable, bundleIdentifier: bundleID, machName: name) } }.value
        if case .failure(let error) = result { Log.security.error("Agent IA indisponible : \(error.localizedDescription, privacy: .public)"); return false }
        return true
    }

    private func startListening() {
        guard eventsTask == nil else { return }
        let events = client.events()
        eventsTask = Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
    }

    private func handle(_ event: AIEvent) {
        switch event {
        case .stateChanged(let current):
            status = current
        case .textDelta(let id, let text):
            if turn?.id == id { turn?.buffer += text }
        case .done(let id, let final, _):
            if let t = turn, t.id == id { turn = nil; t.continuation.resume(returning: final.isEmpty ? t.buffer : final) }
        case .error(let id, let message):
            if let t = turn, id == nil || id == t.id { turn = nil; t.continuation.resume(throwing: AgentFailure(message: message)) }
            else if id == nil { failure = message }
        default: break
        }
        refresh()
    }

    struct AgentFailure: Error, LocalizedError { var message: String; var errorDescription: String? { message } }

    // MARK: Questions

    func ask(_ text: String) {
        guard availability.canAsk, !isRunning else { return }
        if currentTab == nil { currentTab = UUID() }      // aucune page ouverte (ou essai) : une conversation quand même
        let tab = currentTab!
        runTab = tab
        let run = UUID()
        runID = run
        failure = nil
        let context = messages.suffix(6).map { ($0.role == .user ? "Vous : " : "Luciole : ") + String($0.text.prefix(240)) }
        messages += [AIMessage(role: .user, text: text), AIMessage(role: .assistant, text: "")]
        panel.clearComposer()
        agentTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await AgentLoop(environment: self).run(task: text, context: context)
            if self.runID == run { self.finish(outcome, in: tab) }
        }
        refresh()
    }

    private func finish(_ outcome: AgentOutcome, in tab: UUID) {
        var list = conversations[tab] ?? []
        if var last = list.last, last.role == .assistant {
            switch outcome.reason {
            case .done, .stepCap: last.text = outcome.answer
            case .cancelled: if last.text.isEmpty { last.text = "Arrêté." }
            case .failed(let message): failure = message; if last.text.isEmpty { last.text = "Je n'ai pas pu terminer." }
            }
            last.sources = outcome.sources
            list[list.count - 1] = last
            conversations[tab] = list
        }
        agentTask = nil
        runTab = nil
        pending = nil
        refresh()
    }

    func stop() {
        guard agentTask != nil else { return }
        agentTask?.cancel()
        agentTask = nil                    // l'écran est libre tout de suite ; la tâche arrêtée finit en silence (son résultat est ignoré)
        runID = UUID()
        if let tab = runTab, var list = conversations[tab], var last = list.last, last.role == .assistant {
            if last.text.isEmpty { last.text = "Arrêté." }
            list[list.count - 1] = last
            conversations[tab] = list
        }
        runTab = nil
        resolveConfirm(false)
        resolveQuestion(nil)
        if let t = turn { turn = nil; t.continuation.resume(throwing: CancellationError()); cancelling = Task { await client.cancel(taskID: t.id) } }
    }

    private func resolveConfirm(_ ok: Bool) {
        guard let c = confirmContinuation else { return }
        confirmContinuation = nil; pending = nil
        c.resume(returning: ok)
        refresh()
    }

    private func resolveQuestion(_ text: String?) {
        guard let c = questionContinuation else { return }
        questionContinuation = nil; pending = nil
        c.resume(returning: text)
        refresh()
    }

    private func setTrace(_ items: [AgentTraceItem]) {
        guard let tab = runTab, var list = conversations[tab], !list.isEmpty else { return }
        list[list.count - 1].trace = items
        conversations[tab] = list
        refresh()
    }

    // MARK: Modèle

    /// Après l'accord de l'utilisateur (le bouton) : télécharge le modèle avec le moteur de téléchargement d'Orée (reprise, vitesse), puis le service le vérifie.
    private func downloadModel() {
        guard let downloads, downloadID == nil else { return }
        let target = ModelFile.url(for: pin)
        if status?.model == .corrupt { try? FileManager.default.removeItem(at: target) }     // sinon le moteur numéroterait le nouveau fichier
        failure = nil
        download = AIDownloadProgress(received: 0, total: pin.size)
        refresh()
        downloadTask = Task { [weak self] in
            guard let self else { return }
            guard let id = await downloads.startModelDownload(url: self.pin.url, name: self.pin.name, directory: ModelFile.directory) else {
                self.download = nil
                self.failure = "Le téléchargement n'a pas pu démarrer."
                self.refresh()
                return
            }
            self.downloadID = id
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let item = downloads.items.first(where: { $0.id == id }) else { break }
                self.download = AIDownloadProgress(received: item.received, total: item.total ?? self.pin.size)
                self.refresh()
                if item.phase == .finished { break }
                if item.phase == .failed || item.phase == .cancelled { self.failure = item.error ?? "Téléchargement interrompu."; break }
            }
            self.download = nil
            self.downloadID = nil
            await self.prepare()               // le service vérifie le fichier (SHA-256) puis le réveille
        }
    }

    // MARK: Affichage

    private var pageIsReadable: Bool {
        guard let url = hooks.activeWebView()?.url else { return false }
        return !ActionPolicy.isForbiddenPage(url)
    }

    private func refresh() {
        let state = availability
        let list = messages
        let running = isRunning && runTab == currentTab
        let streaming = running && !(list.last?.text.isEmpty ?? true)
        let hasPending = pending != nil && runTab == currentTab
        let pose: LucioleState
        if hasPending { pose = pending.map { if case .question = $0.kind { .ask } else { .wait } } ?? .wait }
        else if running, list.last?.trace.last?.state == .running { pose = .act }
        else { pose = LucioleState.pose(availability: state, running: running, streaming: streaming, failed: failure != nil) }
        var title = "Bonjour. Que puis-je faire pour vous ?", text = "Je tourne sur ce Mac, sans internet. Je peux me tromper : vérifiez ce qui compte."
        var suggestions: [(label: String, fill: String)] = []
        var chip = ""
        var fraction: Double?
        switch state {
        case .connecting: chip = "Réveil"; title = "Un instant…"; text = state.line(modelBytes: pin.size)
        case .unreachable: chip = "Indisponible"; title = "L'IA ne répond pas"; text = state.line(modelBytes: pin.size)
        case .needsModel: chip = "À installer"; title = "L'IA locale n'est pas installée"; text = state.line(modelBytes: pin.size)
        case .downloading(let progress):
            chip = "Téléchargement"; title = "Téléchargement du modèle"; text = state.line(modelBytes: pin.size)
            if let total = progress.total, total > 0 { fraction = Double(progress.received) / Double(total) }
        case .verifying: chip = "Vérification"; title = "Vérification du modèle"; text = state.line(modelBytes: pin.size)
        case .corrupt: chip = "Erreur"; title = "Le modèle est abîmé"; text = state.line(modelBytes: pin.size)
        case .ready:
            if hasPending { chip = "Attend votre accord" }
            else if running { chip = list.last?.trace.last?.state == .running ? "Agit…" : "Réfléchit…" }
            else { chip = "Prêt" }
            if shareContext, pageIsReadable {
                suggestions = [("Résumer cette page", "Résume cette page."), ("Remplir ce formulaire", "Remplis le formulaire de cette page avec mes informations."), ("Chercher sur le web…", "Cherche sur le web : ")]
            } else {
                suggestions = [("Chercher sur le web…", "Cherche sur le web : "), ("Expliquer un mot ou une idée", "Explique-moi simplement : "), ("Écrire un court e-mail", "Écris un court e-mail pour ")]
            }
        }
        if let failure { chip = pose == .err ? "Erreur" : chip; text = failure + (state.canAsk ? "\n" : " ") + text }
        let shows = list.isEmpty || !state.canAsk
        let contextLine: String
        if !pageIsReadable { contextLine = "Page protégée ou vide · non lue" }
        else if !shareContext { contextLine = "Page non partagée · cliquer pour partager" }
        else { contextLine = "Lit : " + (currentTitle.isEmpty ? "cette page" : currentTitle) }
        panel.show(.init(
            pose: pose, chip: chip, context: contextLine,
            title: title, text: text, progress: fraction, offersDownload: state.offersDownload,
            showsEmpty: shows, suggestions: suggestions, canAsk: state.canAsk, running: isRunning,
            placeholder: state.canAsk ? "Demandez quelque chose…" : "L'IA n'est pas encore prête"))
        panel.setTranscript(list, writing: running, pending: hasPending ? pending : nil)
        if let p = pending, !p.armed {            // « Valider » devient actif après 0,8 s : on redessine à ce moment-là
            Task { try? await Task.sleep(for: .milliseconds(850)); self.refresh() }
        }
    }

    // MARK: Automatisation

    /// Dev : ce que le panneau dit et montre (même format que l'ancienne barre, pour `ai_check.py`).
    var report: String {
        let last = messages.last(where: { $0.role == .assistant })
        let trace = last?.trace.map { "\($0.state):\($0.text)" }.joined(separator: " | ") ?? ""
        return "open=\(isOpen) state=\(availability) running=\(isRunning) width=\(Int(width)) pose=\(panel.mascot.state.rawValue) pending=\(pending.map { "\($0.kind)" } ?? "none") trace=[\(trace)] line=\(failure ?? "")| answer=\((last?.text ?? "").replacingOccurrences(of: "\n", with: " ⏎ "))"
    }

    /// Dev : répond à la carte « à valider » ou à la question affichées.
    func devResolve(_ text: String) {
        switch pending?.kind {
        case .confirm: resolveConfirm(text == "yes")
        case .question: resolveQuestion(text)
        case nil: break
        }
    }
}

// MARK: - L'environnement de l'agent : le vrai (modèle, page, recherche, confirmation)

extension AIPanelController: AgentEnvironment {
    /// Dev : chaque tour (consigne comprise) dans le fichier `HB_AI_TRACE`, pour lire ce que dit le modèle.
    private static func logTurn(_ prompt: String, _ text: String) {
        guard let path = ProcessInfo.processInfo.environment["HB_AI_TRACE"] else { return }
        let entry = "=== PROMPT (\(PageMap.estimatedTokens(prompt)) jetons estimés)\n\(prompt)\n=== RÉPONSE\n\(text)\n\n"
        if let handle = FileHandle(forWritingAtPath: path) { handle.seekToEndOfFile(); handle.write(Data(entry.utf8)); try? handle.close() }
        else { try? entry.write(toFile: path, atomically: true, encoding: .utf8) }
    }

    #if DEBUG
    /// Dev (build de debug seulement) : des réponses du modèle écrites à l'avance dans /tmp/oree-ai-script.json (liste de textes), pour tester la boucle
    /// et les cartes sans dépendre d'un petit modèle capricieux. Chaque tour en consomme une.
    private static func scriptedReply() -> String? {
        let path = "/tmp/oree-ai-script.json"
        guard var list = (FileManager.default.contents(atPath: path)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String] }), !list.isEmpty else { return nil }
        let first = list.removeFirst()
        try? JSONSerialization.data(withJSONObject: list).write(to: URL(fileURLWithPath: path))
        return first
    }
    #endif

    func askModel(_ prompt: String) async throws -> String {
        #if DEBUG
        if let scripted = Self.scriptedReply() { Self.logTurn(prompt, scripted); return scripted }
        #endif
        await cancelling?.value
        let request = AIRunRequest(userText: prompt)
        let id = request.taskID
        let text: String = try await withCheckedThrowingContinuation { continuation in
            turn = (id, "", continuation)
            Task { [weak self] in
                guard let self else { return }
                var accepted = await self.client.run(request)
                for _ in 0..<3 where !accepted && self.turn?.id == id {       // le service peut finir d'arrêter l'ancien tour
                    try? await Task.sleep(for: .milliseconds(600))
                    accepted = await self.client.run(request)
                }
                if !accepted, let t = self.turn, t.id == id {
                    self.turn = nil
                    t.continuation.resume(throwing: AgentFailure(message: "Le service IA n'a pas pris la demande. Réessayez dans un instant."))
                }
            }
            // Un tour sans fin de réponse en 90 s : on le dit au lieu d'attendre indéfiniment.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(90))
                guard let self, let t = self.turn, t.id == id else { return }
                self.turn = nil
                await self.client.cancel(taskID: id)
                t.continuation.resume(throwing: AgentFailure(message: "Pas de réponse du service IA depuis 90 secondes."))
            }
        }
        Self.logTurn(prompt, text)
        return text
    }

    /// Carte de la page affichée, réduite pour tenir dans les 4 096 jetons du contexte (avec la réponse et les consignes).
    func pageMap() async -> String? {
        guard shareContext, pageIsReadable, let web = hooks.activeWebView(), let map = await PageMapScript.capture(web) else { return nil }
        return map.render(maxElements: 30, maxText: 1200)
    }

    func perform(_ call: AgentCall) async -> AgentToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any] ?? [:]
        switch call.name {
        case "search_web":
            guard let query = args["query"] as? String, !query.isEmpty else { return AgentToolResult(ok: false, text: "Il manque « query ».", summary: "Requête vide") }
            return await search.search(query)
        case "open_url":
            guard let string = args["url"] as? String, let url = URL(string: string), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return AgentToolResult(ok: false, text: "Adresse refusée : seules les adresses http(s) s'ouvrent.", summary: "Adresse refusée")
            }
            let ok = await hooks.navigate(string)
            return AgentToolResult(ok: ok, text: ok ? "Page ouverte : \(hooks.activeWebView()?.title ?? string)" : "La page n'a pas chargé.", summary: ok ? "Ouverture de \(url.host ?? string)" : "Page non chargée", sources: ok ? [string] : [])
        case "read_page":
            guard pageIsReadable, let web = hooks.activeWebView(), let map = await PageMapScript.capture(web) else { return AgentToolResult(ok: false, text: "Aucune page lisible.", summary: "Page non lisible") }
            return AgentToolResult(ok: true, text: map.render(maxElements: 0, maxText: 2400), summary: "Lecture de la page")
        case "ask_user":
            guard let question = args["question"] as? String, !question.isEmpty else { return AgentToolResult(ok: false, text: "Il manque « question ».") }
            guard let answer = await ask(question) else { return AgentToolResult(ok: false, text: "La personne n'a pas répondu.", summary: "Sans réponse") }
            return AgentToolResult(ok: true, text: "Réponse de la personne : \(answer)", summary: "Réponse reçue")
        default:
            guard let web = hooks.activeWebView() else { return AgentToolResult(ok: false, text: "Aucune page ouverte.") }
            let action: AIAction
            do { action = try AIAction.parse(name: call.name, argumentsJSON: call.argumentsJSON) }
            catch { return AgentToolResult(ok: false, text: "Arguments invalides pour \(call.name) : \(error).", summary: "Arguments invalides") }
            let result = await ActionExecutor.execute(action, in: web, profile: ProfileKeychain().load()) { [weak self] question in
                await self?.confirm(question) ?? false
            }
            return AgentToolResult(ok: result.ok, text: result.message, summary: result.message)
        }
    }

    func ask(_ question: String) async -> String? {
        await withCheckedContinuation { continuation in
            questionContinuation = continuation
            pending = AIPending(kind: .question(question), since: Date())
            refresh()
        }
    }

    private func confirm(_ summary: String) async -> Bool {
        await withCheckedContinuation { continuation in
            confirmContinuation = continuation
            pending = AIPending(kind: .confirm(summary), since: Date())
            refresh()
        }
    }

    func trace(_ items: [AgentTraceItem]) { setTrace(items) }
}
