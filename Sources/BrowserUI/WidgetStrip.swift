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
