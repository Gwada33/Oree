import AppKit
import BrowserCore

/// What shows when the pointer rests on a tab: a picture of the page, its title and site, and what it costs (or "en veille").
@MainActor
final class TabPreviewCard: NSView {
    static let width: CGFloat = 244

    init(image: NSImage?, title: String, host: String, status: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let picture = SurfaceView(fill: Theme.field, cornerRadius: 8)
        picture.translatesAutoresizingMaskIntoConstraints = false
        let imageHeight: CGFloat = 138
        if let image {
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.wantsLayer = true; view.layer?.cornerRadius = 8; view.layer?.masksToBounds = true
            view.translatesAutoresizingMaskIntoConstraints = false
            picture.addSubview(view)
            NSLayoutConstraint.activate([view.topAnchor.constraint(equalTo: picture.topAnchor), view.bottomAnchor.constraint(equalTo: picture.bottomAnchor),
                                         view.leadingAnchor.constraint(equalTo: picture.leadingAnchor), view.trailingAnchor.constraint(equalTo: picture.trailingAnchor)])
        } else {
            let badge = LetterBadgeView(size: 44, cornerRadius: 11)
            badge.configureFavicon(host: host.isEmpty ? title : host, fallbackText: host.isEmpty ? title : host)
            badge.translatesAutoresizingMaskIntoConstraints = false
            picture.addSubview(badge)
            NSLayoutConstraint.activate([badge.centerXAnchor.constraint(equalTo: picture.centerXAnchor), badge.centerYAnchor.constraint(equalTo: picture.centerYAnchor),
                                         badge.widthAnchor.constraint(equalToConstant: 44), badge.heightAnchor.constraint(equalToConstant: 44)])
        }
        stack.addArrangedSubview(picture)
        picture.widthAnchor.constraint(equalToConstant: Self.width - 24).isActive = true
        picture.heightAnchor.constraint(equalToConstant: imageHeight).isActive = true

        func label(_ text: String, font: NSFont, color: NSColor, lines: Int) -> NSTextField {
            let field = oreeLabel(text, font: font, color: color, lines: lines)
            field.isSelectable = false; field.lineBreakMode = .byTruncatingTail
            field.preferredMaxLayoutWidth = Self.width - 24
            return field
        }
        stack.addArrangedSubview(label(title, font: Theme.sans(13, .semibold), color: Theme.text, lines: 2))
        if !host.isEmpty && host != title { stack.addArrangedSubview(label(host, font: Theme.sans(12), color: Theme.muted, lines: 1)) }
        if !status.isEmpty { stack.addArrangedSubview(label(status, font: Theme.sans(11.5), color: Theme.muted, lines: 1)) }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
