import AppKit
import WebKit

/// Lets the extension engine see our tabs: it asks for a tab's title, URL, web view… and
/// tells us to load, reload, activate. Only non-private tabs are ever exposed.
extension Tab: WKWebExtensionTab {
    @objc(windowForWebExtensionContext:)
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { owner }

    @objc(indexInWindowForWebExtensionContext:)
    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        owner?.extensionTabs.firstIndex(where: { $0 === self }) ?? 0
    }

    @objc(webViewForWebExtensionContext:)
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }

    @objc(titleForWebExtensionContext:)
    func title(for context: WKWebExtensionContext) -> String? { displayTitle }

    @objc(isPinnedForWebExtensionContext:)
    func isPinned(for context: WKWebExtensionContext) -> Bool { false }

    @objc(isPlayingAudioForWebExtensionContext:)
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { audioState == .playing }

    @objc(isMutedForWebExtensionContext:)
    func isMuted(for context: WKWebExtensionContext) -> Bool { audioState == .muted }

    @objc(setMuted:forWebExtensionContext:completionHandler:)
    func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if (audioState == .muted) != muted { toggleMute() }
        completionHandler(nil)
    }

    @objc(urlForWebExtensionContext:)
    func url(for context: WKWebExtensionContext) -> URL? { currentURL }

    @objc(isLoadingCompleteForWebExtensionContext:)
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(webView?.isLoading ?? false) }

    @objc(isSelectedForWebExtensionContext:)
    func isSelected(for context: WKWebExtensionContext) -> Bool { owner?.activeExtensionTab === self }

    @objc(activateForWebExtensionContext:completionHandler:)
    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        owner?.selectTab(self)
        completionHandler(nil)
    }

    @objc(loadURL:forWebExtensionContext:completionHandler:)
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        lastRequestedURL = url
        webView?.load(URLRequest(url: url))
        completionHandler(nil)
    }

    @objc(reloadFromOrigin:forWebExtensionContext:completionHandler:)
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { webView?.reloadFromOrigin() } else { webView?.reload() }
        completionHandler(nil)
    }

    @objc(goBackForWebExtensionContext:completionHandler:)
    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView?.goBack()
        completionHandler(nil)
    }

    @objc(goForwardForWebExtensionContext:completionHandler:)
    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        webView?.goForward()
        completionHandler(nil)
    }
}

/// A toolbar button for one extension's action, with its badge text.
@MainActor
final class ExtensionButton: NSButton {
    let extensionID: String
    private let badge = NSTextField(labelWithString: "")

    init(extensionID: String, onClick: @escaping () -> Void) {
        self.extensionID = extensionID
        self.handler = onClick
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        badge.font = .systemFont(ofSize: 8, weight: .bold)
        badge.textColor = .black
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = Theme.accent.cgColor
        badge.layer?.cornerRadius = 5
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 30),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            badge.heightAnchor.constraint(equalToConstant: 10),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private let handler: () -> Void
    @objc private func clicked() { handler() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(from action: WKWebExtension.Action) {
        image = action.icon(for: CGSize(width: 40, height: 40))
        toolTip = action.label
        isEnabled = action.isEnabled
        alphaValue = action.isEnabled ? 1 : 0.4
        badge.stringValue = " \(action.badgeText) "
        badge.isHidden = action.badgeText.isEmpty
        setAccessibilityLabel(action.label.isEmpty ? "Extension" : action.label)
    }
}
