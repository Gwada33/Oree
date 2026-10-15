import AppKit
import BrowserCore

/// What the "site information" popover shows (filled in by the window, drawn by `SiteInfoView`).
struct SiteInfoContent {
    struct CertificateLine { var label: String; var value: String }
    struct PermissionRow { var name: String; var allowed: Bool; var reset: () -> Void }

    var host: String
    var connection: SiteInfoPolicy.Connection
    var certificate: [CertificateLine] = []
    var showCertificate: (() -> Void)?
    var cookieCount: Int?
    var dataSiteName: String?
    var clearData: (() -> Void)?
    var permissions: [PermissionRow] = []
}

/// The popover under the address bar's lock: is the connection safe, who vouches for the site, its cookies and the permissions it was given.
@MainActor
final class SiteInfoView: NSView {
    static let width: CGFloat = 330

    init(_ content: SiteInfoContent) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        func wrapped(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
            let label = oreeLabel(text, font: font, color: color, lines: 0)
            label.isSelectable = false
            label.preferredMaxLayoutWidth = Self.width - 32
            return label
        }
        func section(_ views: [NSView]) {
            for view in views { stack.addArrangedSubview(view) }
        }
        func separator() {
            let line = NSBox(); line.boxType = .separator; line.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(line)
            line.widthAnchor.constraint(equalToConstant: Self.width - 32).isActive = true
        }

        section([wrapped(content.host, font: Theme.sans(15, .semibold), color: Theme.text)])

        let icon = NSImageView()
        icon.image = .oreeSymbol(content.connection.secure ? "lock.fill" : "exclamationmark.triangle.fill", size: 14, weight: .medium) {
            content.connection.secure ? Theme.accent : NSColor.systemOrange
        }
        icon.translatesAutoresizingMaskIntoConstraints = false
        let status = NSStackView(views: [icon, wrapped(content.connection.title, font: Theme.sans(13, .semibold), color: Theme.text)])
        status.spacing = 6
        section([status, wrapped(content.connection.detail, font: Theme.sans(12), color: Theme.muted)])

        if !content.certificate.isEmpty {
            separator()
            for line in content.certificate {
                let row = NSStackView(views: [oreeLabel(line.label, font: Theme.sans(12), color: Theme.muted), wrapped(line.value, font: Theme.sans(12, .medium), color: Theme.text)])
                row.orientation = .vertical; row.alignment = .leading; row.spacing = 0
                stack.addArrangedSubview(row)
            }
            if let show = content.showCertificate { stack.addArrangedSubview(TextButton("Voir le certificat…", style: .secondary, height: 28, onClick: show)) }
        }

        if let count = content.cookieCount {
            separator()
            stack.addArrangedSubview(wrapped(count == 0 ? "Aucun cookie pour ce site." : "\(count) cookie\(count > 1 ? "s" : "") pour ce site.", font: Theme.sans(13), color: Theme.text))
            if let name = content.dataSiteName, let clear = content.clearData {
                stack.addArrangedSubview(TextButton("Effacer les données de \(name)", style: .secondary, height: 28, onClick: clear))
            }
        }

        if !content.permissions.isEmpty {
            separator()
            stack.addArrangedSubview(wrapped("Autorisations", font: Theme.sans(12, .semibold), color: Theme.muted))
            for permission in content.permissions {
                let name = wrapped("\(permission.name) : \(permission.allowed ? "autorisée" : "refusée")", font: Theme.sans(13), color: Theme.text)
                let reset = TextButton("Réinitialiser", style: .ghost, height: 24, onClick: permission.reset)
                let row = NSStackView(views: [name, reset]); row.spacing = 8
                stack.addArrangedSubview(row)
            }
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Informations sur le site \(content.host)")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
