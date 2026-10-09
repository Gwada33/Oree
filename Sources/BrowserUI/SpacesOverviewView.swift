import AppKit
import BrowserCore

/// What the overview shows for one space.
struct SpaceCardData {
    struct Entry { let title: String; let host: String; let sleeping: Bool; let group: String? }
    let index: Int
    let style: SpaceStyle
    let entries: [Entry]
    let isCurrent: Bool
}

/// « Espaces » overview (⌃↑): one card per space with its groups and tabs. Click a card to go
/// there; "Modifier" edits name / icon / hue in place; "+" adds a space; "Supprimer" removes one
/// (its tabs move to the neighbouring space).
@MainActor
final class SpacesOverviewView: NSView {
    var onSelect: ((Int) -> Void)?
    var onUpdate: ((Int, String, OreeTokens.Hue, SpaceIcon) -> Void)?
    var onDelete: ((Int) -> Void)?
    var onAdd: (() -> Void)?
    var onClose: (() -> Void)?
    /// Called to get fresh data every time the cards are rebuilt.
    var provider: (() -> [SpaceCardData])?

    private let scrim = SurfaceView(fill: Theme.chrome)
    private let flow = FlowView()
    private var editingIndex: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        scrim.alphaValue = 0.96
        addSubview(scrim)

        let title = oreeLabel("Espaces", font: Theme.serifItalic(46), color: Theme.text)
        let hint = oreeLabel("Cliquez sur un espace pour y aller. Échap pour fermer.", font: Theme.sans(13), color: Theme.muted)
        let close = ChromeIconButton(symbol: "xmark", label: "Fermer  Échap", size: 32, pointSize: 14)
        close.onClick = { [weak self] in self?.onClose?() }
        [title, hint, close].forEach(addSubview)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        flow.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = flow
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scrim.topAnchor.constraint(equalTo: topAnchor), scrim.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: leadingAnchor), scrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 56),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 56),
            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            hint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            close.topAnchor.constraint(equalTo: topAnchor, constant: 52),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 24),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            flow.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            flow.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            flow.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var isPresented: Bool { !isHidden }

    func present() {
        editingIndex = nil
        rebuild()
        isHidden = false
        alphaValue = 0
        Motion.animate(Motion.standard) { animator().alphaValue = 1 }
        window?.makeFirstResponder(self)
    }

    func dismiss() {
        Motion.animate(Motion.quick, { animator().alphaValue = 0 }, completion: { [weak self] in self?.isHidden = true })
    }

    /// Rebuilds the cards from fresh data (after an edit, add or delete).
    func rebuild() {
        flow.subviews.forEach { $0.removeFromSuperview() }
        for card in provider?() ?? [] {
            let view = SpaceCardView(data: card, editing: editingIndex == card.index)
            view.onOpen = { [weak self] in self?.onSelect?(card.index) }
            view.onEdit = { [weak self] in self?.editingIndex = card.index; self?.rebuild() }
            view.onCancel = { [weak self] in self?.editingIndex = nil; self?.rebuild() }
            view.onSave = { [weak self] name, hue, icon in
                self?.editingIndex = nil
                self?.onUpdate?(card.index, name, hue, icon)
                self?.rebuild()
            }
            view.onDelete = { [weak self] in self?.onDelete?(card.index); self?.rebuild() }
            flow.addSubview(view)
        }
        let add = AddSpaceCard()
        add.onClick = { [weak self] in self?.onAdd?(); self?.rebuild() }
        flow.addSubview(add)
        flow.needsLayout = true
    }

    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) } }
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Lays children out left-to-right, wrapping, with fixed-size cards.
private final class FlowView: NSView {
    override var isFlipped: Bool { true }
    private let spacing: CGFloat = 20

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.fittingSize
            if x > 0, x + size.width > bounds.width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            view.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let h = y + rowHeight + 48
        if abs(frame.height - h) > 1 { setFrameSize(NSSize(width: bounds.width, height: h)) }
        invalidateIntrinsicContentSize()
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) { needsLayout = true }
}

@MainActor
private final class AddSpaceCard: NSView {
    var onClick: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 300), heightAnchor.constraint(equalToConstant: 150)])
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("Nouvel espace")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: Theme.radiusLarge, yRadius: Theme.radiusLarge)
        if hovered { Theme.hover.setFill(); path.fill() }
        Theme.line.setStroke(); path.lineWidth = 1.5; path.setLineDash([5, 4], count: 2, phase: 0); path.stroke()
        let text = NSAttributedString(string: "+  Nouvel espace", attributes: [.font: Theme.sans(14, .semibold), .foregroundColor: Theme.muted])
        let s = text.size(); text.draw(at: NSPoint(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2))
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// One space: header (icon chip, name, count), its tabs grouped, and edit / delete actions.
@MainActor
private final class SpaceCardView: SurfaceView {
    var onOpen: (() -> Void)?, onEdit: (() -> Void)?, onCancel: (() -> Void)?, onDelete: (() -> Void)?
    var onSave: ((String, OreeTokens.Hue, SpaceIcon) -> Void)?
    private let data: SpaceCardData
    private var draftHue: OreeTokens.Hue
    private var draftIcon: SpaceIcon
    private let nameField = NSTextField()
    private var hovered = false { didSet { needsDisplay = true } }

    init(data: SpaceCardData, editing: Bool) {
        self.data = data
        self.draftHue = data.style.hue
        self.draftIcon = data.style.icon
        super.init(fill: Theme.raised, cornerRadius: Theme.radiusLarge)
        border = data.isCurrent ? Theme.hue(data.style.hue) : Theme.line
        elevation = .one
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 300),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
        editing ? buildEditor(in: stack) : buildReadOnly(in: stack)
        setAccessibilityElement(!editing)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Espace \(data.style.name), \(data.entries.count) onglets")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func chip(_ style: SpaceStyle) -> NSView {
        let box = SurfaceView(fill: Theme.hueSoft(style.hue, 0.18), cornerRadius: Theme.radiusSmall + 2)
        let icon = NSImageView(image: .oreeSymbol(style.icon.symbol, size: 14, weight: .medium) { Theme.hueInk(style.hue) })
        icon.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(icon)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 30), box.heightAnchor.constraint(equalToConstant: 30),
            icon.centerXAnchor.constraint(equalTo: box.centerXAnchor), icon.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        return box
    }

    private func buildReadOnly(in stack: NSStackView) {
        let name = oreeLabel(data.style.name, font: Theme.Typo.subheading, color: Theme.text)
        let count = oreeLabel("\(data.entries.count) onglet\(data.entries.count > 1 ? "s" : "")", font: Theme.sans(12), color: Theme.muted)
        let titles = NSStackView(views: [name, count]); titles.orientation = .vertical; titles.alignment = .leading; titles.spacing = 0
        let edit = TextButton("Modifier", style: .ghost) { [weak self] in self?.onEdit?() }
        let head = NSStackView(views: [chip(data.style), titles, edit])
        head.orientation = .horizontal; head.alignment = .centerY; head.spacing = 10; head.distribution = .fill
        titles.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(head)
        head.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        var lastGroup: String??
        for entry in data.entries.prefix(8) {
            if entry.group != lastGroup, let group = entry.group {
                stack.addArrangedSubview(oreeLabel(group, font: Theme.sans(11.5, .semibold), color: Theme.muted))
            }
            lastGroup = .some(entry.group)
            let line = oreeLabel(entry.title.isEmpty ? entry.host : entry.title, font: Theme.sans(12.5), color: entry.sleeping ? Theme.muted : Theme.text)
            line.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: entry.group == nil ? 0 : -12).isActive = true
        }
        if data.entries.count > 8 {
            stack.addArrangedSubview(oreeLabel("+ \(data.entries.count - 8) autres", font: Theme.sans(12), color: Theme.muted))
        }
        if data.entries.isEmpty { stack.addArrangedSubview(oreeLabel("Aucun onglet", font: Theme.sans(12.5), color: Theme.muted)) }
        heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    }

    private func buildEditor(in stack: NSStackView) {
        stack.addArrangedSubview(oreeLabel("NOM", font: Theme.sans(11, .semibold), color: Theme.muted))
        nameField.stringValue = data.style.name
        nameField.font = Theme.sans(14)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.setAccessibilityLabel("Nom de l’espace")
        stack.addArrangedSubview(nameField)
        nameField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addArrangedSubview(oreeLabel("ICÔNE", font: Theme.sans(11, .semibold), color: Theme.muted))
        let icons = SpaceIcon.allCases
        let picker = SegmentedPills(options: icons.map { _ in "" }, selected: icons.firstIndex(of: draftIcon) ?? 0)
        let iconRow = IconPicker(icons: icons, selected: draftIcon, hue: { [weak self] in self?.draftHue ?? .mousse }) { [weak self] icon in self?.draftIcon = icon }
        _ = picker
        stack.addArrangedSubview(iconRow)
        iconRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addArrangedSubview(oreeLabel("TEINTE", font: Theme.sans(11, .semibold), color: Theme.muted))
        let swatches = SwatchRow(selected: draftHue) { [weak self] hue in self?.draftHue = hue; iconRow.needsDisplay = true }
        stack.addArrangedSubview(swatches)

        let save = TextButton("Enregistrer", style: .primary) { [weak self] in
            guard let self else { return }
            let name = self.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self.onSave?(name.isEmpty ? self.data.style.name : String(name.prefix(14)), self.draftHue, self.draftIcon)
        }
        let cancel = TextButton("Annuler", style: .ghost) { [weak self] in self?.onCancel?() }
        var buttons: [NSView] = [save, cancel]
        let spacer = NSView(); buttons.append(spacer)
        let delete = TextButton("Supprimer", style: .ghost) { [weak self] in self?.onDelete?() }
        if data.index >= 0, onDelete != nil || true { buttons.append(delete) }
        let row = NSStackView(views: buttons); row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        heightAnchor.constraint(greaterThanOrEqualToConstant: 290).isActive = true
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking the card (not a button) opens the space — read-only mode only.
        if nameField.superview == nil { onOpen?() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onOpen?(); return true }
}

/// The 8 space icons in a row; the chosen one is filled with the draft hue.
@MainActor
private final class IconPicker: NSView {
    private let icons: [SpaceIcon]
    private var selected: SpaceIcon
    private let hue: () -> OreeTokens.Hue
    private let onPick: (SpaceIcon) -> Void

    init(icons: [SpaceIcon], selected: SpaceIcon, hue: @escaping () -> OreeTokens.Hue, onPick: @escaping (SpaceIcon) -> Void) {
        self.icons = icons; self.selected = selected; self.hue = hue; self.onPick = onPick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        setAccessibilityElement(true); setAccessibilityRole(.radioGroup); setAccessibilityLabel("Icône")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func cell(_ i: Int) -> NSRect { NSRect(x: CGFloat(i) * 34, y: 0, width: 30, height: 30) }
    override func draw(_ dirtyRect: NSRect) {
        for (i, icon) in icons.enumerated() {
            let r = cell(i)
            let on = icon == selected
            (on ? Theme.hue(hue()) : Theme.hover).setFill()
            NSBezierPath(roundedRect: r, xRadius: Theme.radiusSmall + 2, yRadius: Theme.radiusSmall + 2).fill()
            let tint = on ? Theme.onHue(hue()) : Theme.muted
            let image = NSImage.oreeSymbol(icon.symbol, size: 13, weight: .medium) { tint }
            let s = image.size
            image.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
        }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = icons.indices.first(where: { cell($0).contains(p) }) else { return }
        selected = icons[i]; onPick(selected); needsDisplay = true
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
