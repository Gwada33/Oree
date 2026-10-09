import AppKit
import BrowserCore

/// One line of a side panel (favorites, history, downloads, reading list).
struct PanelEntry {
    enum Icon { case site(String), symbol(String) }
    let icon: Icon
    let title: String
    let subtitle: String?
    let open: () -> Void
    let remove: (() -> Void)?
}

struct PanelSection {
    let title: String?
    let entries: [PanelEntry]
}

/// Replaces the tab list in the sidebar with a titled list ("← Historique"), grouped in sections.
@MainActor
final class SidePanelView: NSView {
    var onBack: (() -> Void)?
    private let titleLabel = oreeLabel("", font: Theme.Typo.subheading, color: Theme.text)
    private let listStack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        let back = ChromeIconButton(symbol: "chevron.left", label: "Revenir aux onglets", size: 28, pointSize: 12)
        back.onClick = { [weak self] in self?.onBack?() }
        let header = NSStackView(views: [back, titleLabel]); header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false
        listStack.orientation = .vertical; listStack.alignment = .width; listStack.spacing = 1
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        let doc = FlippedDocumentView(); doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        doc.addSubview(listStack)
        addSubview(header); addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            listStack.topAnchor.constraint(equalTo: doc.topAnchor), listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor), listStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(title: String, sections: [PanelSection], emptyText: String) {
        titleLabel.stringValue = title
        listStack.arrangedSubviews.forEach { listStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let total = sections.reduce(0) { $0 + $1.entries.count }
        if total == 0 { listStack.addArrangedSubview(oreeLabel(emptyText, font: Theme.sans(12.5), color: Theme.muted, lines: 3)) }
        for section in sections where !section.entries.isEmpty {
            if let name = section.title { listStack.addArrangedSubview(makeSectionLabel(name)) }
            for entry in section.entries { listStack.addArrangedSubview(PanelRow(entry: entry)) }
        }
        isHidden = false
    }
}

@MainActor
private final class PanelRow: HoverView {
    private let entry: PanelEntry
    override var hovered: Bool { didSet { removeButton?.alphaValue = hovered ? 1 : 0 } }
    private var removeButton: ChromeIconButton?

    init(entry: PanelEntry) {
        self.entry = entry
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let icon: NSView
        switch entry.icon {
        case .site(let host):
            let badge = LetterBadgeView(size: 20, cornerRadius: 5)
            badge.configureFavicon(host: host, fallbackText: host)
            icon = badge
        case .symbol(let name):
            icon = NSImageView(image: .oreeSymbol(name, size: 13) { Theme.muted })
        }
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = oreeLabel(entry.title, font: Theme.sans(13, .medium), color: Theme.text)
        title.lineBreakMode = .byTruncatingTail
        let sub = oreeLabel(entry.subtitle ?? "", font: Theme.sans(11.5), color: Theme.muted)
        sub.lineBreakMode = .byTruncatingTail
        let texts = NSStackView(views: entry.subtitle == nil ? [title] : [title, sub])
        texts.orientation = .vertical; texts.alignment = .leading; texts.spacing = 0
        texts.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon); addSubview(texts)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: entry.subtitle == nil ? 34 : 44),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            texts.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if let remove = entry.remove {
            let b = ChromeIconButton(symbol: "xmark", label: "Retirer", size: 24, pointSize: 10)
            b.onClick = remove
            b.alphaValue = 0
            addSubview(b)
            NSLayoutConstraint.activate([
                b.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                b.centerYAnchor.constraint(equalTo: centerYAnchor),
                texts.trailingAnchor.constraint(lessThanOrEqualTo: b.leadingAnchor, constant: -4),
            ])
            removeButton = b
        } else {
            texts.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8).isActive = true
        }
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel(entry.title + (entry.subtitle.map { ", " + $0 } ?? ""))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard hover > 0.001 else { return }
        Theme.hover.scaled(hover).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Theme.radiusSmall + 2, yRadius: Theme.radiusSmall + 2).fill()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { entry.open() }
    override func accessibilityPerformPress() -> Bool { entry.open(); return true }
}
