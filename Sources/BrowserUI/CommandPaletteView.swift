import AppKit

enum PaletteFilter: Int, CaseIterable {
    case all, tabs, history, bookmarks, actions

    var title: String {
        switch self {
        case .all: return "Tout"
        case .tabs: return "Onglets"
        case .history: return "Historique"
        case .bookmarks: return "Favoris"
        case .actions: return "Actions"
        }
    }
}

/// One selectable row in the palette.
struct PaletteItem {
    enum Icon {
        case site(host: String)
        case symbol(String)
    }

    let icon: Icon
    let title: String
    let subtitle: String?
    /// Right-aligned hint, e.g. "Basculer ↵" or "hier".
    let trailing: String?
    let perform: @MainActor (_ openInNewTab: Bool) -> Void
}

struct PaletteSection {
    let title: String
    let items: [PaletteItem]
}

/// ⌘T / ⌘L command palette: type to jump to a tab, a history entry, a
/// favorite, an action — or just enter an address / search. Replaces the
/// system text-completion popup, which fought with the field editor.
@MainActor
final class CommandPaletteView: NSView, NSTextFieldDelegate {
    /// Supplies results for the current query and filter.
    var provider: ((String, PaletteFilter) -> [PaletteSection])?

    private let dim = NSView()
    private let card = NSView()
    private let field = NSTextField()
    private let chipsStack = NSStackView()
    private let resultsStack = NSStackView()
    private let scroll = NSScrollView()
    private var cardTop: NSLayoutConstraint!

    private var filter: PaletteFilter = .all
    private var rows: [PaletteRowView] = []
    private var items: [PaletteItem] = []
    private var selected = 0
    private var opensInNewTab = false
    private var chipButtons: [NSButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var isPresented: Bool { !isHidden }

    // MARK: Build

    private func build() {
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
        dim.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dim)

        card.wantsLayer = true
        card.layer?.cornerRadius = 16
        card.layer?.backgroundColor = Theme.raised.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Theme.line.cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.5
        card.layer?.shadowRadius = 30
        card.layer?.shadowOffset = CGSize(width: 0, height: -12)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        icon.contentTintColor = Theme.tertiaryText
        icon.translatesAutoresizingMaskIntoConstraints = false

        field.font = .systemFont(ofSize: 18, weight: .regular)
        field.textColor = Theme.text
        field.placeholderAttributedString = NSAttributedString(
            string: "Rechercher ou saisir une adresse",
            attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: Theme.quietText]
        )
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityLabel("Recherche")

        let esc = NSTextField(labelWithString: "esc")
        esc.font = Theme.monoFont
        esc.textColor = Theme.tertiaryText
        esc.wantsLayer = true
        esc.layer?.backgroundColor = Theme.hover.cgColor
        esc.layer?.cornerRadius = 5
        esc.translatesAutoresizingMaskIntoConstraints = false

        let separator1 = NSView()
        separator1.wantsLayer = true
        separator1.layer?.backgroundColor = Theme.divider.cgColor
        separator1.translatesAutoresizingMaskIntoConstraints = false

        chipsStack.orientation = .horizontal
        chipsStack.spacing = 4
        chipsStack.translatesAutoresizingMaskIntoConstraints = false
        for chip in PaletteFilter.allCases {
            let button = NSButton(title: chip.title, target: self, action: #selector(chipTapped(_:)))
            button.tag = chip.rawValue
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
            button.font = .systemFont(ofSize: 12.5, weight: .regular)
            button.setAccessibilityLabel("Filtre \(chip.title)")
            let textWidth = (chip.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium)]).width
            button.widthAnchor.constraint(equalToConstant: ceil(textWidth) + 22).isActive = true
            chipButtons.append(button)
            chipsStack.addArrangedSubview(button)
        }

        resultsStack.orientation = .vertical
        resultsStack.spacing = 1
        resultsStack.alignment = .leading
        resultsStack.translatesAutoresizingMaskIntoConstraints = false

        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(resultsStack)
        scroll.documentView = flipped
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false

        [icon, field, esc, separator1, chipsStack, scroll].forEach(card.addSubview)

        cardTop = card.topAnchor.constraint(equalTo: topAnchor, constant: 90)
        NSLayoutConstraint.activate([
            dim.topAnchor.constraint(equalTo: topAnchor),
            dim.bottomAnchor.constraint(equalTo: bottomAnchor),
            dim.leadingAnchor.constraint(equalTo: leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: trailingAnchor),

            cardTop,
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.widthAnchor.constraint(equalToConstant: 680),
            card.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -40),

            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            icon.widthAnchor.constraint(equalToConstant: 18),

            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: esc.leadingAnchor, constant: -12),
            field.centerYAnchor.constraint(equalTo: icon.centerYAnchor),

            esc.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            esc.centerYAnchor.constraint(equalTo: icon.centerYAnchor),

            separator1.topAnchor.constraint(equalTo: card.topAnchor, constant: 58),
            separator1.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            separator1.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            separator1.heightAnchor.constraint(equalToConstant: 1),

            chipsStack.topAnchor.constraint(equalTo: separator1.bottomAnchor, constant: 10),
            chipsStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            chipsStack.heightAnchor.constraint(equalToConstant: 26),

            scroll.topAnchor.constraint(equalTo: chipsStack.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 420),

            resultsStack.topAnchor.constraint(equalTo: flipped.topAnchor),
            resultsStack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            resultsStack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            resultsStack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        // Shrink-wrap short result lists (the <= 420 cap above wins for long ones).
        let wrap = scroll.heightAnchor.constraint(equalTo: flipped.heightAnchor)
        wrap.priority = .defaultHigh
        wrap.isActive = true

        updateChips(animated: false)
    }

    // MARK: Present / dismiss

    func present(initialText: String, selectAll: Bool, opensInNewTab: Bool, in window: NSWindow?) {
        self.opensInNewTab = opensInNewTab
        filter = .all
        updateChips(animated: false)
        field.stringValue = initialText
        reload()

        isHidden = false
        alphaValue = 0
        cardTop.constant = 104
        layoutSubtreeIfNeeded()
        cardTop.constant = 90
        Motion.animate(Motion.standard) {
            animator().alphaValue = 1
            layoutSubtreeIfNeeded()
        }
        window?.makeFirstResponder(field)
        if selectAll { field.currentEditor()?.selectAll(nil) } else { field.currentEditor()?.moveToEndOfLine(nil) }
    }

    func dismiss(restoringFocusTo target: NSResponder?) {
        guard isPresented else { return }
        Motion.animate(Motion.quick, {
            animator().alphaValue = 0
        }, completion: { [weak self] in
            self?.isHidden = true
        })
        if let target { window?.makeFirstResponder(target) }
    }

    /// Set by the controller so Esc / outside-click hand focus back to the page.
    var onDismiss: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !card.frame.contains(point) { onDismiss?() }
    }

    // MARK: Results

    private func reload() {
        let sections = provider?(field.stringValue, filter) ?? []
        rows.forEach { $0.removeFromSuperview() }
        resultsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = []
        items = []

        for section in sections where !section.items.isEmpty {
            let header = NSTextField(labelWithString: section.title)
            header.font = .systemFont(ofSize: 11.5, weight: .medium)
            header.textColor = Theme.tertiaryText
            let wrapper = NSView()
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            header.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(header)
            NSLayoutConstraint.activate([
                header.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 12),
                header.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -4),
                wrapper.heightAnchor.constraint(equalToConstant: 30),
            ])
            resultsStack.addArrangedSubview(wrapper)
            wrapper.widthAnchor.constraint(equalTo: resultsStack.widthAnchor).isActive = true

            for item in section.items {
                let index = items.count
                let row = PaletteRowView(item: item, query: field.stringValue)
                row.onHover = { [weak self] in self?.select(index, scroll: false) }
                row.onClick = { [weak self] in self?.select(index, scroll: false); self?.activateSelected(forceNewTab: false) }
                resultsStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: resultsStack.widthAnchor).isActive = true
                rows.append(row)
                items.append(item)
            }
        }
        if items.isEmpty {
            let empty = NSTextField(labelWithString: "Aucun résultat")
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = Theme.tertiaryText
            let wrapper = NSView()
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            empty.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 12),
                empty.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
                wrapper.heightAnchor.constraint(equalToConstant: 44),
            ])
            resultsStack.addArrangedSubview(wrapper)
            wrapper.widthAnchor.constraint(equalTo: resultsStack.widthAnchor).isActive = true
        }
        select(0, scroll: false)
    }

    private func select(_ index: Int, scroll shouldScroll: Bool) {
        guard !rows.isEmpty else { return }
        selected = max(0, min(index, rows.count - 1))
        for (i, row) in rows.enumerated() { row.isSelected = i == selected }
        if shouldScroll { rows[selected].scrollToVisible(rows[selected].bounds) }
    }

    private func activateSelected(forceNewTab: Bool) {
        guard items.indices.contains(selected) else { return }
        let item = items[selected]
        onDismiss?()
        item.perform(opensInNewTab || forceNewTab)
    }

    // MARK: Chips

    /// Opens straight on one filter (e.g. history for ⌘Y).
    func setFilter(_ newFilter: PaletteFilter) {
        filter = newFilter
        updateChips(animated: false)
        reload()
    }

    @objc private func chipTapped(_ sender: NSButton) {
        filter = PaletteFilter(rawValue: sender.tag) ?? .all
        updateChips(animated: true)
        reload()
        window?.makeFirstResponder(field)
    }

    private func updateChips(animated: Bool) {
        for button in chipButtons {
            let active = button.tag == filter.rawValue
            button.attributedTitle = NSAttributedString(
                string: PaletteFilter(rawValue: button.tag)?.title ?? "",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: active ? .medium : .regular),
                    .foregroundColor: active ? Theme.text : Theme.tertiaryText,
                    .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }(),
                ]
            )
            button.layer?.backgroundColor = (active ? Theme.press : .clear).cgColor
        }
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) { reload() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): select(selected + 1, scroll: true); return true
        case #selector(NSResponder.moveUp(_:)): select(selected - 1, scroll: true); return true
        case #selector(NSResponder.insertNewline(_:)):
            let command = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
            activateSelected(forceNewTab: command)
            return true
        case #selector(NSResponder.cancelOperation(_:)): onDismiss?(); return true
        case #selector(NSResponder.insertTab(_:)):
            filter = PaletteFilter(rawValue: (filter.rawValue + 1) % PaletteFilter.allCases.count) ?? .all
            updateChips(animated: true)
            reload()
            return true
        default: return false
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A result row: icon, title with the matched part in the accent color,
/// optional subtitle, trailing hint. The selected row gets the accent ring.
@MainActor
private final class PaletteRowView: NSView {
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    private let ring = CALayer()

    var isSelected = false {
        didSet {
            Motion.transaction(Motion.quick) { ring.opacity = isSelected ? 1 : 0 }
            setAccessibilityValue(isSelected ? "Sélectionné" : nil)
        }
    }

    init(item: PaletteItem, query: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        ring.cornerRadius = 10
        ring.backgroundColor = Theme.accentSoft.cgColor
        ring.borderColor = Theme.accent.withAlphaComponent(0.45).cgColor
        ring.borderWidth = 1
        ring.opacity = 0
        layer?.addSublayer(ring)

        let iconView: NSView
        switch item.icon {
        case .site(let host):
            let badge = LetterBadgeView(size: 24, cornerRadius: 7)
            badge.configureFavicon(host: host, fallbackText: host)
            iconView = badge
        case .symbol(let name):
            let image = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
            image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            image.contentTintColor = Theme.secondaryText
            image.translatesAutoresizingMaskIntoConstraints = false
            image.widthAnchor.constraint(equalToConstant: 24).isActive = true
            iconView = image
        }

        let title = NSTextField(labelWithAttributedString: Self.highlighted(item.title, query: query))
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [title])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        if let subtitle = item.subtitle {
            let sub = NSTextField(labelWithString: subtitle)
            sub.font = Theme.monoFont
            sub.textColor = Theme.tertiaryText
            sub.lineBreakMode = .byTruncatingMiddle
            stack.addArrangedSubview(sub)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false

        let trailing = NSTextField(labelWithString: item.trailing ?? "")
        trailing.font = item.trailing?.count ?? 0 <= 4 ? Theme.monoFont : .systemFont(ofSize: 12)
        trailing.textColor = Theme.tertiaryText
        trailing.translatesAutoresizingMaskIntoConstraints = false

        [iconView, stack, trailing].forEach(addSubview)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),

            stack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -12),

            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: item.subtitle == nil ? 40 : 48),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(item.title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func highlighted(_ text: String, query: String) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: Theme.text]
        )
        let needle = query.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty, let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
            result.addAttribute(.foregroundColor, value: Theme.accent, range: NSRange(range, in: text))
        }
        return result
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { if !isSelected { onHover?() } }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
