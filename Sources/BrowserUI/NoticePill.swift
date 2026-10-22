import AppKit
import BrowserCore

/// A small floating offer at the bottom of the page ("Adresse copiée · Ouvrir dans Plans"). It fades out by itself and never
/// takes focus.
@MainActor
final class NoticePill: SurfaceView {
    private let label = oreeLabel("", font: Theme.sans(12.5, .medium), color: Theme.text)
    private let stack = NSStackView()
    private var action: TextButton?
    private var hideTask: Task<Void, Never>?

    init() {
        super.init(fill: Theme.raised, cornerRadius: 18)
        border = Theme.line
        elevation = .two
        isHidden = true
        alphaValue = 0
        let close = ChromeIconButton(symbol: "xmark", label: "Fermer", size: 24, pointSize: 10)
        close.onClick = { [weak self] in self?.dismiss() }
        [label, close].forEach(stack.addArrangedSubview)
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The text on show, nil when hidden (automation).
    var visibleMessage: String? { isHidden ? nil : label.stringValue }

    /// Shows the offer for `seconds`; `perform` runs when the button is pressed.
    func show(message: String, button: String, seconds: Double = 8, perform: @escaping () -> Void) {
        label.stringValue = message
        action?.removeFromSuperview()
        let fresh = TextButton(button, style: .primary) { [weak self] in perform(); self?.dismiss() }   // a title is fixed at creation
        stack.insertArrangedSubview(fresh, at: 1)
        action = fresh
        isHidden = false
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; animator().alphaValue = 1 }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.dismiss() }
        }
    }

    /// Presses the offer's button (automation).
    func pressAction() { action?.onClick?() }

    func dismiss() {
        hideTask?.cancel()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; animator().alphaValue = 0 }, completionHandler: { [weak self] in
            mainActorNow { if self?.alphaValue == 0 { self?.isHidden = true } }
        })
    }
}
