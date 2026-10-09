import AppKit
import UniformTypeIdentifiers
import BrowserCore
import DownloadKit

/// 4 pt progress bar whose fill glides to each new value (design-system motion; no glide with reduced motion).
@MainActor
final class DownloadProgressBar: NSView {
    @objc dynamic var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    var indeterminate = false { didSet { needsDisplay = true } }
    var dimmed = false { didSet { needsDisplay = true } }
    var failed = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 4).isActive = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "fraction" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    func setFraction(_ value: Double, animated: Bool) {
        let target = CGFloat(max(0, min(1, value)))
        guard animated, !Motion.reduced else { fraction = target; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .linear)   // continuous progress reads best linear
            context.allowsImplicitAnimation = true
            animator().fraction = target
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2)
        Theme.press.setFill(); track.fill()
        let width: CGFloat = indeterminate ? bounds.width * 0.3 : max(bounds.height, bounds.width * fraction)
        guard width > 0, indeterminate || fraction > 0 else { return }
        var rect = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        if indeterminate {
            // A soft sweep, driven by the clock (a redraw every 50 ms while visible).
            let phase = CGFloat((Date().timeIntervalSinceReferenceDate * 0.8).truncatingRemainder(dividingBy: 1))
            rect.origin.x = (bounds.width + width) * phase - width
            NSGraphicsContext.saveGraphicsState(); track.addClip()
        }
        (failed ? Theme.hue(.brique) : dimmed ? Theme.muted : Theme.accent).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        if indeterminate { NSGraphicsContext.restoreGraphicsState() }
    }
}

/// One download: type icon, name, status line, progress bar and the buttons that make sense for its state.
@MainActor
final class DownloadRowView: HoverView {
    var onPause: (() -> Void)?, onResume: (() -> Void)?, onCancel: (() -> Void)?
    var onRemove: (() -> Void)?, onReveal: (() -> Void)?, onOpen: (() -> Void)?
    private(set) var itemID: UUID
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let bar = DownloadProgressBar()
    private let buttons = NSStackView()
    private var shownPhase: DownloadPhase?
    private var canOpen = false
    private static var iconCache: [String: NSImage] = [:]
    private nonisolated(unsafe) var sweep: Timer?

    init(id: UUID) {
        itemID = id
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        for label in [title, detail] { label.translatesAutoresizingMaskIntoConstraints = false; label.lineBreakMode = .byTruncatingMiddle }
        title.font = Theme.sans(13, .semibold); title.textColor = Theme.text
        detail.font = Theme.sans(12); detail.textColor = Theme.muted; detail.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons.orientation = .horizontal; buttons.spacing = 2; buttons.alignment = .centerY
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.setContentHuggingPriority(.required, for: .horizontal)
        [icon, title, detail, bar, buttons].forEach(addSubview)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 64),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 34), icon.heightAnchor.constraint(equalToConstant: 34),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            bar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -10),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { sweep?.invalidate() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { sweep?.invalidate(); sweep = nil }
    }

    func configure(_ item: DownloadsController.Item, animated: Bool) {
        title.stringValue = item.name
        let snapshot = item.snapshot
        switch item.phase {
        case .probing, .running:
            detail.stringValue = ByteFormat.progressLine(snapshot) + (item.throttled ? " · ralenti pendant le chargement d’une page" : "")
        case .paused: detail.stringValue = "En pause · " + ByteFormat.progressLine(snapshot)
        case .finished: detail.stringValue = (item.total.map { ByteFormat.size($0) } ?? ByteFormat.size(item.received)) + " · Terminé"
        case .failed: detail.stringValue = item.error ?? "Échec du téléchargement"
        case .cancelled: detail.stringValue = "Annulé"
        }
        detail.textColor = item.phase == .failed ? Theme.hue(.brique) : Theme.muted
        let showsBar = item.phase == .running || item.phase == .paused || item.phase == .probing
        bar.isHidden = !showsBar
        bar.dimmed = item.phase == .paused
        bar.indeterminate = showsBar && item.fraction == nil && item.phase == .running
        updateSweep()
        if let fraction = item.fraction { bar.setFraction(fraction, animated: animated) }
        canOpen = item.phase == .finished
        toolTip = item.phase == .running ? "\(item.connections) connexion\(item.connections > 1 ? "s" : "") · \(item.sources) serveur\(item.sources > 1 ? "s" : "")" : nil
        itemID = item.id
        setAccessibilityLabel("\(item.name), \(detail.stringValue)")
        updateIcon(item)
        if shownPhase != item.phase { shownPhase = item.phase; rebuildButtons(item) }
    }

    private func updateSweep() {
        if bar.indeterminate, !Motion.reduced, sweep == nil {
            sweep = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak bar] _ in MainActor.assumeIsolated { bar?.needsDisplay = true } }
        } else if !bar.indeterminate { sweep?.invalidate(); sweep = nil }
    }

    private func updateIcon(_ item: DownloadsController.Item) {
        if let file = item.fileURL, FileManager.default.fileExists(atPath: file.path) {
            icon.image = NSWorkspace.shared.icon(forFile: file.path); return
        }
        let ext = (item.name as NSString).pathExtension.lowercased()
        if let cached = Self.iconCache[ext] { icon.image = cached; return }
        let image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        Self.iconCache[ext] = image
        icon.image = image
    }

    private func rebuildButtons(_ item: DownloadsController.Item) {
        buttons.arrangedSubviews.forEach { buttons.removeArrangedSubview($0); $0.removeFromSuperview() }
        func add(_ symbol: String, _ label: String, _ action: @escaping () -> Void) {
            let button = ChromeIconButton(symbol: symbol, label: label, size: 26, pointSize: 12)
            button.onClick = action
            buttons.addArrangedSubview(button)
        }
        switch item.phase {
        case .probing, .running:
            add("pause.fill", "Mettre en pause") { [weak self] in self?.onPause?() }
            add("xmark", "Annuler") { [weak self] in self?.onCancel?() }
        case .paused:
            add("play.fill", "Reprendre") { [weak self] in self?.onResume?() }
            add("xmark", "Annuler") { [weak self] in self?.onCancel?() }
        case .failed:
            add("arrow.clockwise", "Réessayer") { [weak self] in self?.onResume?() }
            add("xmark", "Retirer de la liste") { [weak self] in self?.onRemove?() }
        case .finished:
            add("magnifyingglass", "Afficher dans le Finder") { [weak self] in self?.onReveal?() }
            add("xmark", "Retirer de la liste") { [weak self] in self?.onRemove?() }
        case .cancelled:
            add("xmark", "Retirer de la liste") { [weak self] in self?.onRemove?() }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hover > 0.001 else { return }
        Theme.hover.scaled(hover).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: Theme.radius, yRadius: Theme.radius).fill()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { if canOpen { onOpen?() } }
}

/// The downloads window (popover): header with the overall state, one row per file.
@MainActor
final class DownloadsPanelView: NSView {
    private unowned let controller: DownloadsController
    private let titleLabel = oreeLabel("Téléchargements", font: Theme.Typo.subheading, color: Theme.text)
    private let subtitle = oreeLabel("", font: Theme.sans(12), color: Theme.muted)
    private lazy var clearButton = TextButton("Tout effacer", style: .ghost) { [weak self] in self?.controller.clearFinished() }
    private let list = NSStackView()
    private let empty = oreeLabel("Les fichiers que vous téléchargez apparaîtront ici.", font: Theme.sans(12.5), color: Theme.muted, lines: 2)
    private var rows: [UUID: DownloadRowView] = [:]
    private var heightConstraint: NSLayoutConstraint!
    static let width: CGFloat = 392

    init(controller: DownloadsController) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        translatesAutoresizingMaskIntoConstraints = false
        let heading = NSStackView(views: [titleLabel, subtitle])
        heading.orientation = .vertical; heading.alignment = .leading; heading.spacing = 1
        heading.translatesAutoresizingMaskIntoConstraints = false
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        list.orientation = .vertical; list.alignment = .width; list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        let doc = FlippedDocumentView(); doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        doc.addSubview(list)
        let separator = SurfaceView(fill: Theme.line); separator.translatesAutoresizingMaskIntoConstraints = false
        empty.translatesAutoresizingMaskIntoConstraints = false
        [heading, clearButton, separator, scroll, empty].forEach(addSubview)
        heightConstraint = heightAnchor.constraint(equalToConstant: 200)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width), heightConstraint,
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 14), heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            clearButton.centerYAnchor.constraint(equalTo: heading.centerYAnchor), clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            separator.topAnchor.constraint(equalTo: topAnchor, constant: 58), separator.leadingAnchor.constraint(equalTo: leadingAnchor), separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4), scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor), list.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor), list.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor), empty.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 20),
            empty.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
        ])
        refresh(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Re-reads the controller: updates rows in place (no flicker), adds new ones, drops removed ones.
    func refresh(animated: Bool = true) {
        let items = controller.items
        let summary = controller.summary
        subtitle.stringValue = summary.running == 0 ? (items.isEmpty ? "Aucun téléchargement" : "Aucun en cours")
            : "\(summary.running) en cours · \(ByteFormat.speed(summary.bytesPerSecond))"
        clearButton.isHidden = !items.contains { $0.phase == .finished || $0.phase == .failed || $0.phase == .cancelled }
        empty.isHidden = !items.isEmpty

        let ids = Set(items.map(\.id))
        for (id, row) in rows where !ids.contains(id) { list.removeArrangedSubview(row); row.removeFromSuperview(); rows[id] = nil }
        for (index, item) in items.enumerated() {
            let row: DownloadRowView
            if let existing = rows[item.id] { row = existing } else {
                row = DownloadRowView(id: item.id)
                wire(row, id: item.id)
                rows[item.id] = row
                list.insertArrangedSubview(row, at: min(index, list.arrangedSubviews.count))
                if animated, !Motion.reduced { row.alphaValue = 0; Motion.animate(Motion.standard) { row.animator().alphaValue = 1 } }
            }
            row.configure(item, animated: animated)
            if list.arrangedSubviews.firstIndex(of: row) != index {
                list.removeArrangedSubview(row); list.insertArrangedSubview(row, at: min(index, list.arrangedSubviews.count))
            }
        }
        let rowsHeight = CGFloat(items.count) * 64
        heightConstraint.constant = items.isEmpty ? 150 : min(480, 66 + rowsHeight + 8)
    }

    private func wire(_ row: DownloadRowView, id: UUID) {
        row.onPause = { [weak self] in self?.controller.pause(id) }
        row.onResume = { [weak self] in self?.controller.resume(id) }
        row.onCancel = { [weak self] in self?.controller.cancel(id) }
        row.onRemove = { [weak self] in self?.controller.remove(id) }
        row.onReveal = { [weak self] in self?.controller.reveal(id) }
        row.onOpen = { [weak self] in self?.controller.open(id) }
    }
}
