import AppKit

/// What a full-page warning/recovery screen says and offers.
struct Interstitial {
    struct Action {
        let title: String
        let isPrimary: Bool
        let handler: @MainActor () -> Void
    }

    let symbolName: String
    let title: String
    let message: String
    let actions: [Action]
}

/// A full-page screen shown over a tab's web view: crash recovery, "this
/// site doesn't support HTTPS", "this site looks dangerous". It sits above
/// the web view in the tab's content slot, so it also swallows clicks meant
/// for the page underneath.
@MainActor
final class InterstitialView: NSView {
    private var handlers: [@MainActor () -> Void] = []
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.card.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        stack.orientation = .vertical
        stack.spacing = 14
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ model: Interstitial) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        handlers = model.actions.map(\.handler)

        let icon = NSImageView(image: NSImage(systemSymbolName: model.symbolName, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        let title = NSTextField(wrappingLabelWithString: model.title)
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.alignment = .center
        title.setAccessibilityRole(.staticText)

        let message = NSTextField(wrappingLabelWithString: model.message)
        message.font = .systemFont(ofSize: 13)
        message.textColor = .secondaryLabelColor
        message.alignment = .center

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        for (index, action) in model.actions.enumerated() {
            let button = NSButton(title: action.title, target: self, action: #selector(actionTapped(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            if action.isPrimary { button.keyEquivalent = "\r" }
            buttons.addArrangedSubview(button)
        }

        [icon, title, message, buttons].forEach { stack.addArrangedSubview($0) }
        isHidden = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(model.title)
    }

    func hide() {
        isHidden = true
        handlers = []
    }

    @objc private func actionTapped(_ sender: NSButton) {
        guard handlers.indices.contains(sender.tag) else { return }
        handlers[sender.tag]()
    }
}

extension Interstitial {
    static func crashed(reload: @escaping @MainActor () -> Void) -> Interstitial {
        Interstitial(
            symbolName: "exclamationmark.triangle",
            title: "Cette page s'est arrêtée",
            message: "Le processus qui affichait cette page a planté. Vos autres onglets ne sont pas affectés.",
            actions: [.init(title: "Recharger", isPrimary: true, handler: reload)]
        )
    }

    static func loadFailed(
        host: String,
        reason: String,
        retry: @escaping @MainActor () -> Void
    ) -> Interstitial {
        Interstitial(
            symbolName: "wifi.exclamationmark",
            title: "Impossible d'ouvrir cette page",
            message: "\(reason)\n\n\(host)",
            actions: [.init(title: "Réessayer", isPrimary: true, handler: retry)]
        )
    }

    /// Shown for an invalid/expired/untrusted certificate. There is deliberately no
    /// "continue anyway" button: the page is not opened at all.
    static func connectionNotPrivate(
        host: String,
        reason: String,
        goBack: @escaping @MainActor () -> Void
    ) -> Interstitial {
        Interstitial(
            symbolName: "lock.trianglebadge.exclamationmark",
            title: "Connexion non privée",
            message: "L'identité de « \(host) » n'a pas pu être vérifiée : \(reason). Quelqu'un pourrait intercepter ce que vous échangez avec ce site. Par sécurité, la page n'a pas été ouverte.",
            actions: [.init(title: "Retour", isPrimary: true, handler: goBack)]
        )
    }

    static func httpFallback(
        host: String,
        goBack: @escaping @MainActor () -> Void,
        continueOverHTTP: @escaping @MainActor () -> Void
    ) -> Interstitial {
        Interstitial(
            symbolName: "lock.open",
            title: "Connexion non sécurisée",
            message: "« \(host) » ne prend pas en charge HTTPS. Si vous continuez, ce que vous échangez avec ce site (mots de passe, formulaires) pourra être lu par des tiers sur le réseau.",
            actions: [
                .init(title: "Retour", isPrimary: true, handler: goBack),
                .init(title: "Continuer en HTTP", isPrimary: false, handler: continueOverHTTP),
            ]
        )
    }

    static func unsafeSite(
        host: String,
        threatDescription: String,
        goBack: @escaping @MainActor () -> Void,
        proceed: @escaping @MainActor () -> Void
    ) -> Interstitial {
        Interstitial(
            symbolName: "xmark.shield",
            title: "Site potentiellement dangereux",
            message: "« \(host) » est signalé par Google Safe Browsing comme \(threatDescription). Il pourrait tenter de voler vos informations ou d'installer des logiciels malveillants.",
            actions: [
                .init(title: "Retour en lieu sûr", isPrimary: true, handler: goBack),
                .init(title: "Ignorer l'avertissement", isPrimary: false, handler: proceed),
            ]
        )
    }
}
