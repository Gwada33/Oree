import AppKit
import BrowserCore
import BrowserStorage

/// Notes: a small pad in a popover. It opens on the note about the page in front (or the last one you edited), saves by itself while you
/// type, and the ▾ button lists the others. Everything stays on this Mac.
@MainActor
final class NotesPanelView: NSView, NSTextViewDelegate {
    static let size = NSSize(width: 380, height: 440)
    private let repo: NoteRepository
    private let pageURL: String?
    private(set) var note: Note
    private let titleLabel = oreeLabel("", font: Theme.sans(13, .semibold), color: Theme.text)
    private let subtitleLabel = oreeLabel("", font: Theme.sans(11.5), color: Theme.muted)
    private let textView = NSTextView()
    private var saveWork: DispatchWorkItem?
    private var changing = false

    init(repo: NoteRepository, pageURL: String?, append: String? = nil) {
        self.repo = repo
        self.pageURL = pageURL
        let existing = pageURL.flatMap { try? repo.latest(forURL: $0) } ?? nil
        self.note = existing ?? ((try? repo.all().first) ?? nil) ?? Note(url: pageURL)
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        translatesAutoresizingMaskIntoConstraints = false
        setupViews()
        show(note)
        if let append, !append.isEmpty { self.append(append) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupViews() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView.drawsBackground = false
        textView.font = Theme.sans(13.5)
        textView.textColor = Theme.text
        textView.insertionPointColor = Theme.accent
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 14, height: 10)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.delegate = self
        textView.setAccessibilityLabel("Texte de la note")
        scroll.documentView = textView

        let list = ChromeIconButton(symbol: "chevron.down", label: "Toutes les notes")
        let add = ChromeIconButton(symbol: "square.and.pencil", label: "Nouvelle note")
        let trash = ChromeIconButton(symbol: "trash", label: "Supprimer la note")
        list.onClick = { [weak self, weak list] in if let list { self?.showList(from: list) } }
        add.onClick = { [weak self] in self?.newNote() }
        trash.onClick = { [weak self] in self?.deleteCurrent() }
        let texts = NSStackView(views: [titleLabel, subtitleLabel])
        texts.orientation = .vertical; texts.alignment = .leading; texts.spacing = 1
        titleLabel.lineBreakMode = .byTruncatingTail; subtitleLabel.lineBreakMode = .byTruncatingTail
        let buttons = NSStackView(views: [list, add, trash])
        buttons.spacing = 2
        let bar = NSView()
        for v in [texts, buttons] { v.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(v) }
        bar.translatesAutoresizingMaskIntoConstraints = false
        let rule = SurfaceView(fill: Theme.line)
        rule.translatesAutoresizingMaskIntoConstraints = false
        for v in [bar, rule, scroll] { addSubview(v) }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width), heightAnchor.constraint(equalToConstant: Self.size.height),
            bar.topAnchor.constraint(equalTo: topAnchor), bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor), bar.heightAnchor.constraint(equalToConstant: 52),
            texts.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16), texts.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10), buttons.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8),
            rule.topAnchor.constraint(equalTo: bar.bottomAnchor), rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor), rule.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func show(_ note: Note) {
        self.note = note
        changing = true
        textView.string = note.body
        changing = false
        titleLabel.stringValue = note.title
        subtitleLabel.stringValue = note.url.flatMap { URL(string: $0)?.host } ?? "Note libre"
    }

    func focusText() { window?.makeFirstResponder(textView) }

    /// Adds text at the end (a selection from a page), with its source address under it.
    func append(_ text: String) {
        let source = pageURL.map { "\n— \($0)" } ?? ""
        let separator = textView.string.isEmpty ? "" : "\n\n"
        textView.string += separator + text + source
        textDidChange(Notification(name: NSText.didChangeNotification))
    }

    func textDidChange(_ notification: Notification) {
        guard !changing else { return }
        note.body = textView.string
        titleLabel.stringValue = note.title
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in mainActorNow { self?.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes the note now (also when the pad closes). An empty note that was never saved stays unsaved.
    func saveNow() {
        saveWork?.cancel()
        guard note.id != nil || !note.body.isEmpty else { return }
        if let saved = try? repo.save(note) { note.id = saved.id }
    }

    private func newNote() {
        saveNow()
        show(Note(url: pageURL))
        focusText()
    }

    private func deleteCurrent() {
        saveWork?.cancel()
        if let id = note.id { try? repo.delete(id: id) }
        show((try? repo.all().first) ?? Note(url: pageURL))
    }

    private func showList(from anchor: NSView) {
        saveNow()
        let menu = NSMenu()
        let notes = (try? repo.all()) ?? []
        if notes.isEmpty { let none = NSMenuItem(title: "Aucune note", action: nil, keyEquivalent: ""); none.isEnabled = false; menu.addItem(none) }
        for item in notes.prefix(40) {
            let entry = ClosureMenuItem(title: item.title) { [weak self] in self?.show(item) }
            entry.state = item.id == note.id ? .on : .off
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }
}
