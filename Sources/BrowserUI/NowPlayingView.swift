import AppKit
import BrowserCore

/// Thin, clickable progress bar of the now-playing card: a click or a drag asks for that fraction of the media.
@MainActor
final class MediaProgressBar: NSView {
    var onSeek: ((Double) -> Void)?
    /// 0…1; nil for a live stream (the bar is then an empty line and does not react).
    var progress: Double? { didSet { needsLayout = true } }
    private let track = CALayer()
    private let fill = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(track); layer?.addSublayer(fill)
        track.cornerRadius = 1.5; fill.cornerRadius = 1.5
        setAccessibilityRole(.slider); setAccessibilityLabel("Position de lecture")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 14) }

    override func layout() {
        super.layout()
        let y = (bounds.height - 3) / 2
        track.frame = CGRect(x: 0, y: y, width: bounds.width, height: 3)
        fill.frame = CGRect(x: 0, y: y, width: bounds.width * CGFloat(progress ?? 0), height: 3)
        track.backgroundColor = Theme.cg(Theme.press, in: self)
        fill.backgroundColor = Theme.cg(Theme.accent, in: self)
    }

    override func viewDidChangeEffectiveAppearance() { needsLayout = true }

    private func seek(_ event: NSEvent) {
        guard progress != nil, bounds.width > 0 else { return }
        let x = convert(event.locationInWindow, from: nil).x
        onSeek?(Double(min(max(x / bounds.width, 0), 1)))
    }
    override func mouseDown(with event: NSEvent) { seek(event) }
    override func mouseDragged(with event: NSEvent) { seek(event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// "Now playing" card at the bottom of the sidebar (like Arc's): what plays and where, play/pause, ±10 s, a seekable bar,
/// picture in picture, and the output device (headphones, with their battery when they report it).
@MainActor
final class NowPlayingView: NSView {
    var onTogglePlay: (() -> Void)?
    var onSkip: ((Double) -> Void)?
    var onSeek: ((Double) -> Void)?
    var onPictureInPicture: (() -> Void)?
    /// Asked for the next playback speed.
    var onRate: (() -> Void)?
    var onShowTab: (() -> Void)?

    private let box = SurfaceView(fill: Theme.raised, cornerRadius: 12)
    private let badge = LetterBadgeView(size: 38, cornerRadius: 9)
    private let cover = NSImageView()
    private let titleLabel = oreeLabel("", font: Theme.sans(13, .semibold), color: Theme.text)
    private let subtitleLabel = oreeLabel("", font: Theme.sans(11.5), color: Theme.muted)
    private let bar = MediaProgressBar()
    private let elapsed = oreeLabel("0:00", font: Theme.sans(10.5), color: Theme.muted)
    private let total = oreeLabel("0:00", font: Theme.sans(10.5), color: Theme.muted)
    private let back = ChromeIconButton(symbol: "gobackward.10", label: "Reculer de 10 secondes")
    private let play = ChromeIconButton(symbol: "pause.fill", label: "Pause")
    private let forward = ChromeIconButton(symbol: "goforward.10", label: "Avancer de 10 secondes")
    private let pip = ChromeIconButton(symbol: "pip.enter", label: "Image dans l’image")
    private let rateButton = NSButton(title: "1×", target: nil, action: nil)
    private let deviceIcon = NSImageView()
    private let deviceLabel = oreeLabel("", font: Theme.sans(11), color: Theme.muted)
    private var collapsedHeight: NSLayoutConstraint!

    /// Whether the card takes any room (hidden = 0 pt high, so the tab list gets the space back).
    var isShown = false { didSet { isHidden = !isShown; collapsedHeight.isActive = !isShown } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        box.translatesAutoresizingMaskIntoConstraints = false
        box.border = Theme.line
        addSubview(box)
        collapsedHeight = heightAnchor.constraint(equalToConstant: 0)
        collapsedHeight.isActive = true
        isHidden = true

        cover.imageScaling = .scaleProportionallyUpOrDown
        cover.wantsLayer = true; cover.layer?.cornerRadius = 8; cover.layer?.masksToBounds = true
        cover.isHidden = true
        for view in [badge, cover] { view.translatesAutoresizingMaskIntoConstraints = false }
        for label in [titleLabel, subtitleLabel, elapsed, total, deviceLabel] { label.isSelectable = false }
        titleLabel.lineBreakMode = .byTruncatingTail; subtitleLabel.lineBreakMode = .byTruncatingTail
        deviceLabel.lineBreakMode = .byTruncatingTail
        deviceIcon.translatesAutoresizingMaskIntoConstraints = false
        deviceIcon.setAccessibilityElement(false)
        back.onClick = { [weak self] in self?.onSkip?(-10) }
        forward.onClick = { [weak self] in self?.onSkip?(10) }
        play.onClick = { [weak self] in self?.onTogglePlay?() }
        pip.onClick = { [weak self] in self?.onPictureInPicture?() }
        bar.onSeek = { [weak self] in self?.onSeek?($0) }
        bar.translatesAutoresizingMaskIntoConstraints = false
        let open = NSClickGestureRecognizer(target: self, action: #selector(showTab))
        let header = NSStackView(views: [badge, cover]); header.translatesAutoresizingMaskIntoConstraints = false
        let texts = NSStackView(views: [titleLabel, subtitleLabel]); texts.orientation = .vertical; texts.alignment = .leading; texts.spacing = 1
        texts.translatesAutoresizingMaskIntoConstraints = false
        texts.addGestureRecognizer(open)

        rateButton.isBordered = false
        rateButton.font = Theme.sans(11.5, .semibold)
        rateButton.contentTintColor = Theme.muted
        rateButton.target = self; rateButton.action = #selector(rateClicked)
        rateButton.setAccessibilityLabel("Vitesse de lecture")
        rateButton.translatesAutoresizingMaskIntoConstraints = false
        let controls = NSStackView(views: [back, play, forward]); controls.spacing = 4; controls.translatesAutoresizingMaskIntoConstraints = false
        let device = NSStackView(views: [deviceIcon, deviceLabel]); device.spacing = 4; device.translatesAutoresizingMaskIntoConstraints = false
        [header, texts, pip, bar, elapsed, total, controls, rateButton, device].forEach(box.addSubview)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor, constant: 6), box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor), box.bottomAnchor.constraint(equalTo: bottomAnchor),

            header.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10), header.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            header.widthAnchor.constraint(equalToConstant: 38), header.heightAnchor.constraint(equalToConstant: 38),
            badge.widthAnchor.constraint(equalToConstant: 38), badge.heightAnchor.constraint(equalToConstant: 38),
            cover.widthAnchor.constraint(equalToConstant: 38), cover.heightAnchor.constraint(equalToConstant: 38),
            texts.leadingAnchor.constraint(equalTo: header.trailingAnchor, constant: 9), texts.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            texts.trailingAnchor.constraint(equalTo: pip.leadingAnchor, constant: -6),
            pip.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8), pip.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            bar.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10), bar.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            bar.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6), bar.heightAnchor.constraint(equalToConstant: 14),
            elapsed.leadingAnchor.constraint(equalTo: bar.leadingAnchor), elapsed.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 0),
            total.trailingAnchor.constraint(equalTo: bar.trailingAnchor), total.topAnchor.constraint(equalTo: elapsed.topAnchor),

            controls.topAnchor.constraint(equalTo: elapsed.bottomAnchor, constant: 2), controls.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            rateButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor), rateButton.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            device.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 4),
            device.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10), device.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -10),
            device.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -9),
        ])
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Lecture en cours")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func showTab() { onShowTab?() }
    @objc private func rateClicked() { onRate?() }

    /// `deviceLine` e.g. "AirPods de Nolhan · 80 %"; nil hides the row's text (the speakers of the Mac still get an icon).
    func update(_ info: MediaInfo, host: String, deviceSymbol: String, deviceLine: String) {
        titleLabel.stringValue = info.title.isEmpty ? host : info.title
        subtitleLabel.stringValue = info.artist.isEmpty ? host : "\(info.artist) · \(host)"
        badge.configureFavicon(host: host, fallbackText: host)
        bar.progress = info.progress
        elapsed.stringValue = MediaPolicy.clock(info.position)
        total.stringValue = info.isLive ? "direct" : MediaPolicy.clock(info.duration)
        play.symbol = info.paused ? "play.fill" : "pause.fill"
        play.setAccessibilityLabel(info.paused ? "Lecture" : "Pause")
        pip.isHidden = !info.hasVideo
        pip.symbol = info.pictureInPicture ? "pip.exit" : "pip.enter"
        back.isEnabled = !info.isLive; forward.isEnabled = !info.isLive
        rateButton.title = MediaPolicy.rateLabel(info.rate)
        rateButton.contentTintColor = info.rate == 1 ? Theme.muted : Theme.accent       // a changed speed shows
        deviceIcon.image = .oreeSymbol(deviceSymbol, size: 11, weight: .regular) { Theme.muted }
        deviceLabel.stringValue = deviceLine
    }

    func setArtwork(_ image: NSImage?) {
        cover.image = image
        cover.isHidden = image == nil
        badge.isHidden = image != nil
    }

    /// What the card says, for tests and the automation channel.
    var summary: String { "\(titleLabel.stringValue) | \(subtitleLabel.stringValue) | \(elapsed.stringValue)/\(total.stringValue) | \(deviceLabel.stringValue) | shown=\(isShown)" }
}
