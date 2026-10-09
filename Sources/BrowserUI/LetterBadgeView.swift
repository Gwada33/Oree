import AppKit

/// A small rounded site icon tile: shows a real favicon once one loads, a
/// colored letter badge as the immediate placeholder/fallback otherwise.
/// Used both as a decorative icon inside sidebar tab rows and as a clickable
/// pinned-site shortcut (set `onClick` to make it interactive; otherwise it
/// passes clicks straight through to whatever it's nested in).
final class LetterBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let imageView = NSImageView()
    var onClick: (() -> Void)?

    init(size: CGFloat, cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius

        label.font = .systemFont(ofSize: size * 0.42, weight: .semibold)
        label.textColor = Theme.onHue(.mousse)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = cornerRadius * 0.6
        imageView.layer?.masksToBounds = true
        imageView.isHidden = true
        imageView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(imageView)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])

        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Letter-badge only, no favicon fetch. Used for things that aren't a
    /// real site (e.g. nothing today, kept for completeness/tests).
    func configure(text: String) {
        applyFallback(text: text)
    }

    /// Letter badge immediately, then swaps to the real favicon once (if) it loads.
    func configureFavicon(host: String, fallbackText: String) {
        // The app's own home page has no site: it wears the Orée mark instead of a letter.
        if host.hasSuffix("Nouvel onglet") { applyMark(); return }
        if isMarkShown { mark.isHidden = true; isMarkShown = false }
        applyFallback(text: fallbackText)
        currentHost = host
        FaviconLoader.shared.icon(for: host) { [weak self] image in
            guard let self, let image else { return }
            // The badge may have been reused for a different tab by the time
            // the async fetch completes; only apply if it's still relevant.
            guard self.currentHost == host else { return }
            self.imageView.image = image
            self.imageView.isHidden = false
            self.label.isHidden = true
            self.layer?.backgroundColor = NSColor.white.cgColor   // favicons are drawn on white
        }
    }

    /// 16 pt, 4-bar version (the badge is smaller than 48 pt, so the mark picks it by itself).
    private lazy var mark: OreeMark = {
        let mark = OreeMark(size: 14, simplified: true)
        addSubview(mark)
        NSLayoutConstraint.activate([
            mark.centerXAnchor.constraint(equalTo: centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        return mark
    }()

    private var isMarkShown = false

    private func applyMark() {
        currentHost = nil
        fallbackKey = nil
        label.isHidden = true
        imageView.isHidden = true
        mark.isHidden = false
        isMarkShown = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    private var currentHost: String?
    private var fallbackKey: String?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let key = fallbackKey, !label.isHidden {
            layer?.backgroundColor = Theme.cg(Theme.badgeColor(for: key), in: self)
        }
    }

    private func applyFallback(text: String) {
        currentHost = nil
        if isMarkShown { mark.isHidden = true; isMarkShown = false }
        let letter = text.first.map { String($0).uppercased() } ?? "?"
        label.stringValue = letter
        label.isHidden = false
        imageView.isHidden = true
        fallbackKey = text
        label.textColor = Theme.onHue(Theme.badgeHue(for: text))
        layer?.backgroundColor = Theme.cg(Theme.badgeColor(for: text), in: self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        onClick == nil ? nil : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
