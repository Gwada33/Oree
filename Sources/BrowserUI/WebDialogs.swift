import AppKit
import WebKit
import BrowserCore

/// The windows a page can ask for and that a WKWebView does nothing about unless the app answers: choose a file to upload,
/// `alert()`, `confirm()`, `prompt()`, and `window.close()`. Without them an upload button did nothing, `confirm()` always said no
/// and `alert()` never showed.
extension BrowserWindowController {
    // MARK: Choose a file (<input type="file">)

    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        // Tests cannot click in a system panel: this variable stands in for the user's choice (never set in normal use).
        if let path = ProcessInfo.processInfo.environment["HB_TEST_UPLOAD_PATH"] { completionHandler([URL(fileURLWithPath: path)]); return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.message = "Choisis le fichier à envoyer à \(frame.request.url?.host ?? "ce site")"
        panel.prompt = "Choisir"
        guard let window else { completionHandler(panel.runModal() == .OK ? panel.urls : nil); return }
        panel.beginSheetModal(for: window) { response in completionHandler(response == .OK ? panel.urls : nil) }
    }

    // MARK: alert / confirm / prompt

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping @MainActor @Sendable () -> Void) {
        present(WebDialogPolicy.alert(message: message, frame: frame.request.url), for: webView, field: nil) { _ in completionHandler() }
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        present(WebDialogPolicy.confirm(message: message, frame: frame.request.url), for: webView, field: nil) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        present(WebDialogPolicy.prompt(message: prompt, frame: frame.request.url), for: webView, field: field) { response in
            completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    /// `window.close()` from a page that a script opened: closes its tab.
    public func webViewDidClose(_ webView: WKWebView) {
        // A sign-in popup typically does `opener.postMessage(result); window.close()` in one go: closing at once would drop that message
        // before the page that opened it has received it. A short delay lets it arrive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak webView] in
            guard let self, let webView, let tab = self.tabs.first(where: { $0.webView === webView }) else { return }
            self.closeTab(tab)
        }
    }

    private func present(_ content: WebDialogContent, for webView: WKWebView, field: NSTextField?, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        // A dialog from a tab in the background: bring that tab forward so that the user sees whose it is.
        if let tab = tabs.first(where: { $0.webView === webView }), tab.id != activeTabID { selectTab(tab) }
        let alert = NSAlert()
        alert.messageText = content.title
        alert.informativeText = content.message
        alert.alertStyle = .informational
        alert.addButton(withTitle: content.confirmTitle)
        if let cancel = content.cancelTitle { alert.addButton(withTitle: cancel) }
        alert.accessoryView = field
        if field != nil { alert.window.initialFirstResponder = field }
        activeWebDialog = alert
        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.activeWebDialog = nil
            completion(response)
        }
        if let window { alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { finish(response) } } }
        else { finish(alert.runModal()) }
    }
}

// MARK: Links for other apps

extension BrowserWindowController {
    /// Hands `url` to the app macOS picks for it; with `ask`, only once the user agrees (the site and the app are named).
    func openExternalLink(_ url: URL?, from webView: WKWebView, ask: Bool) {
        guard let url else { return }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            presentNotice("Aucune application ne peut ouvrir ce lien (\(url.scheme ?? "?")).")
            return
        }
        guard ask else { NSWorkspace.shared.open(url); return }
        let appName = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let site = webView.url?.host ?? "Ce site"
        let alert = NSAlert()
        alert.messageText = "« \(site) » veut ouvrir « \(appName) »"
        alert.informativeText = "Ce lien est destiné à une autre application de ce Mac."
        alert.addButton(withTitle: "Ouvrir")
        alert.addButton(withTitle: "Annuler")
        activeWebDialog = alert
        let open: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.activeWebDialog = nil
            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
        }
        if let window { alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { open(response) } } } else { open(alert.runModal()) }
    }
}

// MARK: Username and password asked by a site (HTTP authentication)

extension BrowserWindowController {
    public func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard HTTPAuthPolicy.asksForCredentials(method: space.authenticationMethod) else { completionHandler(.performDefaultHandling, nil); return }
        let user = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); user.placeholderString = "Nom d’utilisateur"
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); password.placeholderString = "Mot de passe"
        user.stringValue = challenge.proposedCredential?.user ?? ""
        let fields = NSStackView(views: [user, password])
        fields.orientation = .vertical; fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 260, height: 56)
        let alert = NSAlert()
        alert.messageText = HTTPAuthPolicy.title(host: space.host, isProxy: space.isProxy())
        alert.informativeText = HTTPAuthPolicy.message(realm: space.realm, secure: space.protocol == "https", failed: challenge.previousFailureCount > 0)
        alert.addButton(withTitle: "Se connecter")
        alert.addButton(withTitle: "Annuler")
        alert.accessoryView = fields
        alert.window.initialFirstResponder = user
        activeWebDialog = alert
        let answer: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.activeWebDialog = nil
            if response == .alertFirstButtonReturn {
                // Kept for this session only: nothing is written to disk.
                completionHandler(.useCredential, URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
        if let window { alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { answer(response) } } } else { answer(alert.runModal()) }
    }
}
