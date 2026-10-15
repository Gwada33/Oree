import AppKit
import BrowserCore

/// The task manager: every tab with what its page costs in memory, so a heavy page is easy to find, put to sleep or close.
@MainActor
final class TaskManagerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    /// Fresh numbers, asked for every two seconds while the window is open.
    var provider: (() -> (snapshot: TaskManagerRows.Snapshot, appBytes: UInt64?))?
    var onSelect: ((UUID) -> Void)?
    var onSleep: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?

    private let table = NSTableView()
    private let summary = oreeLabel("", font: Theme.sans(13, .semibold), color: Theme.text)
    private let detail = oreeLabel("", font: Theme.sans(12), color: Theme.muted)
    private let sleepButton = TextButton("Mettre en veille", style: .secondary, height: 28)
    private let closeButton = TextButton("Fermer l’onglet", style: .secondary, height: 28)
    private var rows: [TaskManagerRows.Row] = []
    private var timer: Timer?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Gestionnaire de tâches"
        window.minSize = NSSize(width: 460, height: 280)
        window.isReleasedWhenClosed = false
        window.backgroundColor = Theme.chrome            // Orée's own paper / ink, whatever the system appearance is
        super.init(window: window)
        build(in: window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build(in window: NSWindow) {
        func column(_ id: String, _ title: String, _ width: CGFloat, min: CGFloat) -> NSTableColumn {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); c.title = title; c.width = width; c.minWidth = min; return c
        }
        let tab = column("tab", "Onglet", 330, min: 160); tab.resizingMask = .autoresizingMask
        table.addTableColumn(tab); table.addTableColumn(column("memory", "Mémoire", 90, min: 70)); table.addTableColumn(column("state", "État", 130, min: 90))
        table.dataSource = self; table.delegate = self
        table.rowHeight = 28; table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = Theme.page; table.gridColor = Theme.line
        table.target = self; table.doubleAction = #selector(openSelected)
        table.setAccessibilityLabel("Onglets et mémoire")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.translatesAutoresizingMaskIntoConstraints = false

        sleepButton.onClick = { [weak self] in self?.sleepSelected() }
        closeButton.onClick = { [weak self] in self?.closeSelected() }
        let buttons = NSStackView(views: [sleepButton, closeButton]); buttons.spacing = 8
        let top = NSStackView(views: [summary, detail]); top.orientation = .vertical; top.alignment = .leading; top.spacing = 2
        let bottomRow = NSStackView(views: [buttons]); bottomRow.alignment = .centerY
        let root = NSStackView(views: [top, scroll, bottomRow]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16); root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = SurfaceView(fill: Theme.chrome, cornerRadius: 0)
        window.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor), root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
        ])
        updateButtons()
    }

    func show() {
        refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    override func close() { timer?.invalidate(); timer = nil; super.close() }

    /// Re-reads the numbers, keeping the selected tab selected.
    func refresh() {
        guard let (snapshot, appBytes) = provider?() else { return }
        let selected = selectedID
        rows = snapshot.rows
        table.reloadData()
        if let selected, let index = rows.firstIndex(where: { $0.id == selected }) { table.selectRowIndexes([index], byExtendingSelection: false) }
        let asleep = rows.filter { $0.state == .sleeping }.count
        summary.stringValue = "\(rows.count) onglet\(rows.count > 1 ? "s" : "") · \(TaskManagerRows.memory(snapshot.totalBytes)) pour les pages" + (appBytes.map { " · \(TaskManagerRows.memory($0)) pour Orée" } ?? "")
        var lines: [String] = []
        if asleep > 0 { lines.append("\(asleep) en veille") }
        if let saved = snapshot.savedBytes { lines.append("la veille t’épargne environ \(TaskManagerRows.memory(saved))") }
        detail.stringValue = lines.joined(separator: " · ")
        updateButtons()
    }

    private var selectedID: UUID? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil }

    private func updateButtons() {
        let row = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
        sleepEnabled = row.map { $0.state != .sleeping } ?? false
        closeEnabled = row != nil
        sleepButton.alphaValue = sleepEnabled ? 1 : 0.4
        closeButton.alphaValue = closeEnabled ? 1 : 0.4
    }

    private var sleepEnabled = false, closeEnabled = false
    @objc private func openSelected() { if let id = selectedID { onSelect?(id) } }
    private func sleepSelected() { if sleepEnabled, let id = selectedID { onSleep?(id); refreshSoon() } }
    private func closeSelected() { if closeEnabled, let id = selectedID { onClose?(id); refreshSoon() } }
    private func refreshSoon() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in MainActor.assumeIsolated { self?.refresh() } } }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return nil }
        let item = rows[row]
        let text: String, color: NSColor
        switch id {
        case "tab": text = item.host.isEmpty || item.host == item.title ? item.title : "\(item.title) — \(item.host)"; color = Theme.text
        case "memory": text = item.state == .sleeping ? "—" : TaskManagerRows.memory(item.bytes) + (item.processTabs > 1 ? " ≈" : ""); color = Theme.text
        default: text = item.state.rawValue + (item.processTabs > 1 && item.state != .sleeping ? " · partagé" : ""); color = item.state == .sleeping ? Theme.muted : Theme.text
        }
        let field = NSTextField(labelWithString: text)
        field.font = Theme.sans(12.5); field.textColor = color; field.lineBreakMode = .byTruncatingTail
        field.alignment = id == "memory" ? .right : .left
        field.toolTip = item.processTabs > 1 ? "Cette page partage son processus avec \(item.processTabs - 1) autre\(item.processTabs > 2 ? "s" : "") onglet\(item.processTabs > 2 ? "s" : "") : la mémoire est répartie." : nil
        let cell = NSTableCellView(); cell.addSubview(field); field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6), field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                                     field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
}
