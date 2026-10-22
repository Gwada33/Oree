import AppKit
import WebKit
import BrowserCore

/// Une pastille : le symbole du widget et sa valeur (« 3 »). Un clic amène à l'onglet qui la fournit.
@MainActor
final class WidgetPillView: SurfaceView {
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(widget: PageWidget, value: String?) {
        super.init(fill: Theme.hueSoft(widget.hue, 0.16), cornerRadius: 12)
        let ink = Theme.hueInk(widget.hue)
        icon.image = NSImage(systemSymbolName: widget.symbol, accessibilityDescription: widget.title)?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        icon.contentTintColor = ink
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = value ?? ""
        label.font = Theme.sans(12, .semibold); label.textColor = ink
        label.isHidden = value == nil
        label.translatesAutoresizingMaskIntoConstraints = false
        [icon, label].forEach(addSubview)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingAnchor.constraint(equalTo: value == nil ? icon.trailingAnchor : label.trailingAnchor, constant: 9),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        toolTip = value.map { "\(widget.title) : \($0)" } ?? widget.title
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(toolTip)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// La rangée de pastilles au pied de la colonne des onglets ; sans pastille elle ne prend aucune place.
@MainActor
final class WidgetStripView: NSView {
    private let stack = NSStackView()
    private var height: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal; stack.spacing = 6; stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        height = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            height, stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor), stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ pills: [WidgetPillView]) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        pills.forEach(stack.addArrangedSubview)
        height.constant = pills.isEmpty ? 0 : 34
    }
}

extension BrowserWindowController {
    /// Les widgets actifs : ceux de l'utilisateur, ou ceux fournis avec Orée tant qu'il n'a rien changé.
    var activeWidgets: [PageWidget] {
        let store = SettingsStore.shared
        guard store.widgetsEnabled else { return [] }
        return (store.pageWidgets ?? WidgetPolicy.builtIn).filter(\.enabled).compactMap(WidgetPolicy.validated).prefix(WidgetPolicy.maxWidgets).map { $0 }
    }

    /// Relit chaque widget sur son onglet (le premier onglet normal, éveillé, du site) et remet les pastilles à jour.
    /// Un site sans onglet ouvert n'a pas de pastille : Orée ne charge jamais une page en cachette.
    func refreshWidgets() {
        let widgets = activeWidgets
        guard !widgets.isEmpty else { widgetStrip.show([]); return }
        Task { @MainActor in
            var pills: [WidgetPillView] = []
            for widget in widgets {
                guard let tab = tabs.first(where: { !$0.isPrivate && !$0.isSuspended && $0.webView != nil && WidgetPolicy.matches(pageHost: $0.currentURL?.host, widgetHost: widget.host) }) else { continue }
                let pill = WidgetPillView(widget: widget, value: WidgetPolicy.display(await widgetValue(widget, in: tab)))
                pill.onClick = { [weak self, weak tab] in if let tab { self?.selectTab(tab) } }
                let menu = NSMenu()
                let remove = ClosureMenuItem(title: "Retirer ce widget") { [weak self] in self?.removeWidget(id: widget.id) }
                menu.addItem(remove)
                pill.menu = menu
                pills.append(pill)
            }
            widgetStrip.show(pills)
        }
    }

    func widgetValue(_ widget: PageWidget, in tab: Tab) async -> String? {
        switch widget.source {
        case .titleCount(let pattern): return WidgetPolicy.capture(in: tab.webView?.title ?? "", pattern: pattern)
        case .count(let selector): return await widgetScript("document.querySelectorAll(\(Self.jsString(selector))).length", in: tab)
        case .text(let selector): return await widgetScript("(document.querySelector(\(Self.jsString(selector))) || {}).textContent || ''", in: tab)
        }
    }

    /// Lecture seule, dans un monde isolé : la page ne voit ni le script ni le résultat.
    private func widgetScript(_ js: String, in tab: Tab) async -> String? {
        guard let web = tab.webView else { return nil }
        let value = try? await web.evaluateJavaScript(js, in: nil, contentWorld: WKContentWorld.world(name: "oree-widgets"))
        return value.map { "\($0)" }
    }

    private static func jsString(_ text: String) -> String {
        (try? JSONSerialization.data(withJSONObject: [text])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }
}

// MARK: - Créer un widget avec le modèle local

extension BrowserWindowController {
    /// Dev : accepte l'aperçu sans dialogue (bancs).
    static var widgetAutoAccept = false

    /// Le relevé de la page des boosts, avec en plus « gras » (combien d'éléments sont en gras : du non lu, du nouveau).
    static let widgetSurvey = BoostScript.survey
        .replacingOccurrences(of: "const out = [];", with: "const boldOf = s => { try { let k = 0, i = 0; for (const el of document.querySelectorAll(s)) { if (++i > 40) break; if (parseInt(getComputedStyle(el).fontWeight, 10) >= 600) k++; } return k; } catch (_) { return 0; } }; const out = [];")
        .replacingOccurrences(of: "out.push({ s: e.s, n: e.n, t, a: area });", with: "out.push({ s: e.s, n: e.n, t, a: area, b: boldOf(e.s) });")
        .replacingOccurrences(of: ".map(({ s, n, t }) => ({ s, n, t }))", with: ".map(({ s, n, t, b }) => ({ s, n, t, b }))")

    /// ⌘K › « Créer un widget pour cette page… » : demande ce qu'il faut suivre, le modèle local d'Apple choisit la valeur d'après la STRUCTURE de la page
    /// (les textes lui arrivent réduits à leur forme), Orée la lit pour de vrai et montre le résultat avant d'ajouter la pastille.
    @objc func createWidgetAction() {
        guard let tab = activeTab, !tab.isPrivate, let web = tab.webView, let host = web.url?.host, TranslationPolicy.canTranslate(url: web.url) else { return }
        if let reason = LocalModel.unavailableReason {
            showSimpleAlert("Créer un widget a besoin du modèle local d'Apple Intelligence.", reason)
            return
        }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "par exemple : le nombre de messages non lus"
        let alert = NSAlert()
        alert.messageText = "Un widget pour \(host)"
        alert.informativeText = "Que voulez-vous voir en un coup d'œil dans la barre latérale ? Le modèle tourne sur votre Mac et ne reçoit que la forme de la page, pas son contenu."
        alert.accessoryView = field
        alert.addButton(withTitle: "Créer")
        alert.addButton(withTitle: "Annuler")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            let request = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !request.isEmpty else { return }
            self?.createWidget(request: request, for: tab)
        }
        DispatchQueue.main.async { field.becomeFirstResponder() }
    }

    func createWidget(request: String, for tab: Tab) {
        guard let web = tab.webView, let host = web.url?.host else { return }
        boostTask?.cancel()
        noticePill.show(message: "Création du widget…", button: "Annuler", seconds: 150) { [weak self] in self?.boostTask?.cancel(); self?.noticePill.dismiss() }
        boostTask = Task { [weak self] in
            guard let self else { return }
            @MainActor func fail(_ text: String) { if !Task.isCancelled { self.noticePill.dismiss(); self.showSimpleAlert("Widget impossible", text) } }
            guard let reply = await web.callJSON(Self.widgetSurvey, world: BoostScript.world, seconds: 15) as? [String: Any],
                  let raw = reply["candidates"] as? [[String: Any]], !raw.isEmpty else { return fail("Je n'ai pas pu lire la structure de cette page.") }
            let surveyed = raw.compactMap { item -> WidgetPrompt.Candidate? in
                guard let selector = item["s"] as? String, let count = (item["n"] as? NSNumber)?.intValue else { return nil }
                return .init(selector: selector, count: count, text: (item["t"] as? String) ?? "", bolds: (item["b"] as? NSNumber)?.intValue ?? 0)
            }
            let candidates = surveyed
            do {
                let started = Date()
                let prompt = WidgetPrompt.prompt(request: request, host: host, title: web.title ?? "", candidates: candidates)
                let answer = try await LocalModel.respond(instructions: WidgetPrompt.instructions, prompt: prompt, seconds: 150)
                #if DEBUG
                try? "candidats=\(candidates.count) prompt=\(prompt.count) car. durée=\(Date().timeIntervalSince(started)) s\nréponse: \(answer)\n".write(toFile: "/tmp/oree-widget-log.txt", atomically: true, encoding: .utf8)
                #endif
                guard !Task.isCancelled else { return }
                guard let widget = WidgetPrompt.widget(fromModel: answer, host: host, request: request, candidates: candidates) else { return fail("Je n'ai rien trouvé sur cette page qui corresponde à « \(request) ».") }
                // Lecture réelle : le widget n'est proposé que s'il lit quelque chose maintenant.
                let value = WidgetPolicy.display(await self.widgetValue(widget, in: tab))
                guard WidgetPolicy.isUsable(widget, value: value) else { return fail("Le widget « \(widget.title) » ne lit rien sur cette page pour l'instant. Essayez d'autres mots, ou sur une page qui montre la valeur.") }
                self.noticePill.dismiss()
                self.confirmWidget(widget, value: value ?? "")
            } catch {
                fail(error as? LocalModel.Failure == .timedOut ? "Le modèle a mis trop de temps à répondre." : "Le modèle n'a pas pu choisir de valeur.")
            }
        }
    }

    private func confirmWidget(_ widget: PageWidget, value: String) {
        if Self.widgetAutoAccept { saveWidget(widget); return }
        let alert = NSAlert()
        alert.messageText = "Ajouter « \(widget.title) » à la barre latérale ?"
        alert.informativeText = "Valeur lue maintenant : \(value) (\(widget.sourceDescription)). La pastille se met à jour tant qu'un onglet de \(widget.host) est ouvert ; clic droit dessus pour la retirer."
        alert.icon = NSImage(systemSymbolName: widget.symbol, accessibilityDescription: nil)
        alert.addButton(withTitle: "Ajouter")
        alert.addButton(withTitle: "Annuler")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in if response == .alertFirstButtonReturn { self?.saveWidget(widget) } }
    }

    func saveWidget(_ widget: PageWidget) {
        var list = SettingsStore.shared.pageWidgets ?? WidgetPolicy.builtIn
        list.removeAll { $0.id == widget.id || ($0.host == widget.host && $0.title == widget.title) }
        list.append(widget)
        SettingsStore.shared.pageWidgets = Array(list.suffix(WidgetPolicy.maxWidgets))
        refreshWidgets()
    }

    func removeWidget(id: String) {
        SettingsStore.shared.pageWidgets = (SettingsStore.shared.pageWidgets ?? WidgetPolicy.builtIn).filter { $0.id != id }
        refreshWidgets()
    }
}
