import AppKit
import WebKit

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

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let zoom = max(pageZoom, 0.1)
        let call = "\(Self.hitTest)(\(point.x / zoom), \((isFlipped ? point.y : bounds.height - point.y) / zoom))"
        Task { @MainActor in
            let json = (try? await evaluateJavaScript(call)) as? String
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
            add("Ouvrir le lien dans un nouvel onglet") { owner?.newTab(urlString: raw, isPrivate: isPrivate) }
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
