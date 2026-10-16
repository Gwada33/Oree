import AppKit
import WebKit
import BrowserCore

/// The page view, with Orée's own right-click menu (link, image, selection, editing, navigation).
/// WebKit's built-in menu isn't relied upon: the hit-test is done in the page, and the menu is ours.
@MainActor
final class OreeWebView: WKWebView {
    weak var tab: Tab?

    private struct Hit: Decodable {
        var link: String?
        var image: String?
        var selection: String?
        var editable: Bool?
    }

    private static let hitTest = """
    (function (x, y) {
      var el = document.elementFromPoint(x, y);
      var a = el && el.closest ? el.closest('a[href]') : null;
      var img = el && el.closest ? el.closest('img, video[poster]') : null;
      var editable = !!(el && (el.isContentEditable || /^(INPUT|TEXTAREA)$/.test(el.tagName)));
      return JSON.stringify({
        link: a ? a.href : null,
        image: img ? (img.currentSrc || img.src || img.poster || null) : null,
        selection: String(window.getSelection ? window.getSelection() : ''),
        editable: editable
      });
    })
    """

    // MARK: Gestes de souris

    private var gestureStart: NSEvent?
    private var gesturePoints: [CGPoint] = []
    private var trail: GestureTrailView?

    /// Le point dans un repère où y croît vers le haut, quel que soit le sens de la vue.
    private func gesturePoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: isFlipped ? -p.y : p.y)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard SettingsStore.shared.mouseGestures else { showContextMenu(for: event); return }
        // Gestes actifs : le menu attend de savoir si c'est un clic ou un trait.
        gestureStart = event
        gesturePoints = [gesturePoint(event)]
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard gestureStart != nil else { super.rightMouseDragged(with: event); return }
        gesturePoints.append(gesturePoint(event))
        let result = MouseGesture.recognize(gesturePoints)
        guard result.isGesture else { return }
        if trail == nil { let view = GestureTrailView(frame: bounds); view.autoresizingMask = [.width, .height]; addSubview(view); trail = view }
        trail?.update(points: gesturePoints.map { CGPoint(x: $0.x, y: isFlipped ? -$0.y : $0.y) }, label: MouseGesture.action(for: result.code)?.label)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let start = gestureStart else { super.rightMouseUp(with: event); return }
        gestureStart = nil
        gesturePoints.append(gesturePoint(event))
        trail?.removeFromSuperview(); trail = nil
        let result = MouseGesture.recognize(gesturePoints)
        gesturePoints = []
        if !result.isGesture { showContextMenu(for: start); return }              // un simple clic droit : le menu s'ouvre comme d'habitude
        if let action = MouseGesture.action(for: result.code) { tab?.owner?.performMouseGesture(action) }
    }

    private func showContextMenu(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let zoom = max(pageZoom, 0.1)
        let call = "\(Self.hitTest)(\(point.x / zoom), \((isFlipped ? point.y : bounds.height - point.y) / zoom))"
        Task { @MainActor in
            let json = await safeEvaluate(call, world: .page) as? String
            let hit = json.flatMap { try? JSONDecoder().decode(Hit.self, from: Data($0.utf8)) } ?? Hit()
            NSMenu.popUpContextMenu(makeMenu(for: hit), with: event, for: self)
        }
    }

    private func makeMenu(for hit: Hit) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, enabled: Bool = true, _ action: @escaping @MainActor () -> Void) {
            let item = ClosureMenuItem(title: title, action: action)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        let isPrivate = tab?.isPrivate ?? false
        let owner = tab?.owner

        if let raw = hit.link, let url = URL(string: raw) {
            add("Ouvrir le lien dans un nouvel onglet") { owner?.journalOpenHow = "link"; owner?.newTab(urlString: raw, isPrivate: isPrivate) }
            if let tab { add("Aperçu du lien") { owner?.peek(url, from: tab) } }
            add("Ouvrir le lien dans une mini-fenêtre") { owner?.openMiniWindow(url: url) }
            add("Copier le lien") { Self.copy(raw) }
            add("Télécharger le fichier lié") { [weak self] in self?.download(url) }
            menu.addItem(.separator())
        }
        if let raw = hit.image, let url = URL(string: raw) {
            add("Ouvrir l'image dans un nouvel onglet") { owner?.newTab(urlString: raw, isPrivate: isPrivate) }
            add("Copier l'adresse de l'image") { Self.copy(raw) }
            add("Enregistrer l'image…") { [weak self] in self?.download(url) }
            menu.addItem(.separator())
        }
        let selection = (hit.selection ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if hit.editable == true {
            add("Couper", enabled: !selection.isEmpty) { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
        }
        if !selection.isEmpty {
            add("Copier") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
            let short = selection.count > 24 ? String(selection.prefix(24)) + "…" : selection
            add("Rechercher « \(short) »") { owner?.newTab(urlString: selection, isPrivate: isPrivate) }
            if !isPrivate { add("Ajouter à ma note") { owner?.openNotes(append: selection) } }
        }
        if hit.editable == true {
            add("Coller") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
        }
        add("Tout sélectionner") { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
        menu.addItem(.separator())
        add("Précédent", enabled: canGoBack) { [weak self] in self?.goBack() }
        add("Suivant", enabled: canGoForward) { [weak self] in self?.goForward() }
        add("Recharger") { [weak self] in self?.reload() }
        if let page = url?.absoluteString {
            menu.addItem(.separator())
            add("Copier l'adresse de la page") { Self.copy(page) }
        }
        return menu
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func download(_ url: URL) {
        let owner = tab?.owner
        startDownload(using: URLRequest(url: url)) { download in download.delegate = owner }
    }
}

/// Le trait que l'on dessine pendant un geste, et ce qu'il va faire ; ne prend jamais la souris.
@MainActor
final class GestureTrailView: NSView {
    private var points: [CGPoint] = []
    private var label: String?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(points: [CGPoint], label: String?) { self.points = points; self.label = label; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count > 1 else { return }
        let path = NSBezierPath()
        path.move(to: points[0])
        for p in points.dropFirst() { path.line(to: p) }
        path.lineWidth = 3; path.lineCapStyle = .round; path.lineJoinStyle = .round
        Theme.accent.withAlphaComponent(0.85).setStroke()
        path.stroke()
        guard let label, let end = points.last else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.sans(12.5, .semibold), .foregroundColor: Theme.text]
        let text = NSAttributedString(string: label, attributes: attributes)
        let size = text.size()
        var box = NSRect(x: end.x + 14, y: end.y + 10, width: size.width + 20, height: size.height + 10)
        box.origin.x = min(box.origin.x, bounds.maxX - box.width - 8); box.origin.y = min(max(box.origin.y, 8), bounds.maxY - box.height - 8)
        Theme.raised.setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        text.draw(at: NSPoint(x: box.minX + 10, y: box.minY + 5))
    }
}
