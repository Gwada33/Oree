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
        if let tab = tabs.first(where: { $0.webView === webView }) { closeTab(tab) }
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
