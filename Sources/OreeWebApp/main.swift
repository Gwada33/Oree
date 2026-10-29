import AppKit
import WebKit
import UserNotifications

/// Une application autonome d'Orée : un site dans sa propre application macOS (processus à elle, icône à elle dans le Dock), qui n'a pas besoin qu'Orée tourne.
/// Pour aller vite :
///  - elle **reste en mémoire** quand on ferme la fenêtre (⌘W la cache ; l'icône du Dock la rouvre à l'instant) ;
///  - au lancement elle montre tout de suite **la dernière image de la page**, la vraie page se recharge dessous (session, défilement, historique restaurés) puis la remplace ;
///  - ses cookies, son cache disque et ses service workers sont à elle et persistants (la page se reconnecte, elle ne se recharge pas de zéro) ;
///  - le blocage de pubs est **natif à WebKit** (règles de contenu compilées une fois, gardées) : les listes sont converties par Orée (moteur Rust) à l'installation ;
///  - notifications, pastille du Dock, téléchargements, ouverture de fichiers, liens externes : natifs macOS.
let launchTime = ProcessInfo.processInfo.systemUptime

struct AppInfo {
    let id: String, name: String, startURL: URL
    var scopeHost: String { Self.normalized(startURL.host) }
    static func normalized(_ h: String?) -> String { let l = (h ?? "").lowercased(); return l.hasPrefix("www.") ? String(l.dropFirst(4)) : l }
    func inScope(_ url: URL) -> Bool {
        guard let s = url.scheme?.lowercased(), s == "http" || s == "https" else { return true }
        let h = Self.normalized(url.host); return !scopeHost.isEmpty && (h == scopeHost || h.hasSuffix("." + scopeHost))
    }
    static func load() -> AppInfo? {
        let d = Bundle.main.infoDictionary ?? [:]
        guard let id = d["OreeAppID"] as? String, let s = d["OreeAppURL"] as? String, let url = URL(string: s) else { return nil }
        return AppInfo(id: id, name: (d["CFBundleName"] as? String) ?? "Application", startURL: url)
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler, NSToolbarDelegate {
    let info: AppInfo
    var window: NSWindow!
    var web: WKWebView!
    var cover: NSImageView?
    var quitting = false
    var selfTest = false
    var timings: [String: Double] = [:]
    var popups: [NSWindow] = []
    private var downloadsDestinations: [ObjectIdentifier: URL] = [:]

    init(info: AppInfo) { self.info = info; super.init() }

    private var support: URL {
        let base = ProcessInfo.processInfo.environment["OREEWEBAPP_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OreeWebApp", isDirectory: true)
        let dir = base.appendingPathComponent(info.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); return dir
    }
    private func ms() -> Double { ((ProcessInfo.processInfo.systemUptime - launchTime) * 1000).rounded() }

    // MARK: Démarrage

    func applicationDidFinishLaunching(_ notification: Notification) {
        selfTest = CommandLine.arguments.contains("--selftest")
        buildMenus()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: info.id) ?? UUID())      // cookies, cache disque, service workers : persistants et propres à l'application
        config.applicationNameForUserAgent = "Version/18.4 Safari/605.1.15"
        config.preferences.isElementFullscreenEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        let content = config.userContentController
        content.add(self, name: "oreeNotify"); content.add(self, name: "oreeBadge")
        content.addUserScript(WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if let css = Bundle.main.resourceURL.flatMap({ try? String(contentsOf: $0.appendingPathComponent("cosmetic.css"), encoding: .utf8) }), !css.isEmpty {
            let escaped = css.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`").replacingOccurrences(of: "$", with: "\\$")
            content.addUserScript(WKUserScript(source: "(()=>{const s=document.createElement('style');s.textContent=`\(escaped)`;(document.head||document.documentElement).appendChild(s);})();", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self; web.uiDelegate = self; web.allowsBackForwardNavigationGestures = true
        web.isInspectable = ProcessInfo.processInfo.environment["OREEAPP_INSPECT"] != nil

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = info.name; window.delegate = self; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 320)
        window.contentView = web
        let toolbar = NSToolbar(identifier: "oree.webapp"); toolbar.delegate = self; toolbar.displayMode = .iconOnly; window.toolbar = toolbar
        window.setFrameAutosaveName("OreeWebApp-\(info.id)")
        if !window.setFrameUsingName("OreeWebApp-\(info.id)") { window.center() }
        showLastImage()
        if selfTest { window.orderBack(nil) } else { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        timings["fenetre"] = ms()
        // Les règles de blocage : déjà compilées (lancements suivants) elles sont là en quelques ms. Au tout premier lancement la compilation prend plusieurs secondes :
        // on attend 1,5 s au plus avant d'afficher la page ; les règles s'appliquent dès qu'elles sont prêtes.
        var started = false
        let start: @MainActor () -> Void = { [self] in if !started { started = true; restoreOrLoad() } }
        Task { @MainActor [self] in await installRules(); timings["regles"] = ms(); start() }
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(1500)); start() }
    }

    // MARK: Cache de l'application : dernière image + état de la page

    private var imageFile: URL { support.appendingPathComponent("derniere-image.png") }
    private var stateFile: URL { support.appendingPathComponent("etat.bin") }

    private func showLastImage() {
        guard let image = NSImage(contentsOf: imageFile), let content = window.contentView else { return }
        let view = NSImageView(image: image); view.imageScaling = .scaleAxesIndependently; view.frame = content.bounds; view.autoresizingMask = [.width, .height]
        content.addSubview(view); cover = view
        timings["imageMontree"] = ms()
    }

    private func dropCover() {
        guard let view = cover else { return }
        cover = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; view.animator().alphaValue = 0 }, completionHandler: { view.removeFromSuperview() })
    }

    func saveState(then done: (@MainActor () -> Void)? = nil) {
        if let state = web.interactionState as? Data { try? state.write(to: stateFile, options: .atomic) }
        let config = WKSnapshotConfiguration()
        web.takeSnapshot(with: config) { [imageFile] image, _ in
            if let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: imageFile, options: .atomic) }
            if let done { DispatchQueue.main.async { MainActor.assumeIsolated { done() } } }
        }
    }

    private func restoreOrLoad() {
        if let data = try? Data(contentsOf: stateFile), data.count > 0 { web.interactionState = data; timings["etatRestaure"] = ms() }
        else { web.load(URLRequest(url: info.startURL)) }
    }

    // MARK: Blocage de contenu natif (règles converties par Orée à l'installation)

    private func installRules() async {
        guard let resources = Bundle.main.resourceURL, let names = try? FileManager.default.contentsOfDirectory(atPath: resources.path).filter({ $0.hasPrefix("rules-") && $0.hasSuffix(".json") }).sorted() else { return }
        let store = WKContentRuleListStore.default()!
        for name in names {
            let identifier = "oree.\(info.id).\(name)"
            let url = resources.appendingPathComponent(name)
            let stamp = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
            let versioned = "\(identifier).\(stamp)"
            if let list = try? await store.contentRuleList(forIdentifier: versioned) { web.configuration.userContentController.add(list); continue }
            guard let json = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let list = try? await store.compileContentRuleList(forIdentifier: versioned, encodedContentRuleList: json) { web.configuration.userContentController.add(list) }
        }
    }

    // MARK: Fenêtre : fermer = cacher (l'application reste en mémoire)

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window && !quitting { saveState(); window.orderOut(nil); return false }
        popups.removeAll { $0 === sender }; return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { quitting = true; saveState(); return .terminateNow }
    func applicationDidResignActive(_ notification: Notification) { if !selfTest { saveState() } }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        if let scheme = url.scheme?.lowercased(), !["http", "https", "about", "blob", "data", "file", "javascript"].contains(scheme) { NSWorkspace.shared.open(url); return .cancel }
        if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame != false, !info.inScope(url) { NSWorkspace.shared.open(url); return .cancel }
        return navigationAction.shouldPerformDownload ? .download : .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse, (http.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().hasPrefix("attachment") { return .download }
        return navigationResponse.canShowMIMEType ? .allow : .download
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { timings["pageCommit"] = timings["pageCommit"] ?? ms() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        timings["pageFinie"] = timings["pageFinie"] ?? ms()
        window.title = webView.title?.isEmpty == false ? webView.title! : info.name
        // La vraie page remplace l'image un instant après avoir peint.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.dropCover() }
        if selfTest {
            let json = (try? JSONSerialization.data(withJSONObject: ["timings": timings, "title": webView.title ?? "", "url": webView.url?.absoluteString ?? ""])) ?? Data()
            print(String(data: json, encoding: .utf8) ?? "{}"); fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { self.quitting = true; self.saveState { exit(0) } } }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { dropCover() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { dropCover() }

    /// window.open : un lien du site se charge ici, un autre site va dans le navigateur ; une fenêtre ouverte par un script (connexion Google, paiement) s'ouvre en petite fenêtre.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if navigationAction.navigationType == .linkActivated { if info.inScope(url) { webView.load(navigationAction.request) } else { NSWorkspace.shared.open(url) }; return nil }
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self; popup.uiDelegate = self
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: windowFeatures.width?.doubleValue ?? 520, height: windowFeatures.height?.doubleValue ?? 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.contentView = popup; win.delegate = self; win.isReleasedWhenClosed = false; win.center(); win.makeKeyAndOrderFront(nil); popups.append(win)
        return popup
    }
    func webViewDidClose(_ webView: WKWebView) { popups.first { $0.contentView === webView }?.close() }

    // MARK: Boîtes de dialogue, fichiers, permissions

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async { dialog(message, buttons: ["OK"]) }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool { dialog(message, buttons: ["OK", "Annuler"]) == .alertFirstButtonReturn }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let field = NSTextField(string: defaultText ?? ""); field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        let alert = NSAlert(); alert.messageText = prompt; alert.accessoryView = field; alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Annuler")
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
    @discardableResult private func dialog(_ message: String, buttons: [String]) -> NSApplication.ModalResponse {
        let alert = NSAlert(); alert.messageText = info.name; alert.informativeText = message; buttons.forEach { alert.addButton(withTitle: $0) }; return alert.runModal()
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = parameters.allowsMultipleSelection; panel.canChooseDirectories = parameters.allowsDirectories
        return panel.runModal() == .OK ? panel.urls : nil
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision { .prompt }

    // MARK: Téléchargements (dans ~/Downloads, comme n'importe quelle application Mac)

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var target = folder.appendingPathComponent(suggestedFilename), n = 1
        while FileManager.default.fileExists(atPath: target.path) {
            let base = (suggestedFilename as NSString).deletingPathExtension, ext = (suggestedFilename as NSString).pathExtension
            target = folder.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")); n += 1
        }
        downloadsDestinations[ObjectIdentifier(download)] = target; return target
    }
    func downloadDidFinish(_ download: WKDownload) {
        if let url = downloadsDestinations.removeValue(forKey: ObjectIdentifier(download)) { NSWorkspace.shared.activateFileViewerSelecting([url]); NSApp.requestUserAttention(.informationalRequest) }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { downloadsDestinations[ObjectIdentifier(download)] = nil }

    // MARK: Notifications et pastille (les API web, branchées sur le système)

    static let bridgeScript = """
    (() => {
      if (window.__oreeBridge) return; window.__oreeBridge = true;
      const post = (h, m) => { try { window.webkit.messageHandlers[h].postMessage(m); } catch (e) {} };
      let permission = 'default'; const waiting = [];
      window.__oreeNotifPermission = (p) => { permission = p; while (waiting.length) waiting.shift()(p); };
      class OreeNotification extends EventTarget {
        constructor(title, options = {}) { super(); this.title = title; this.body = options.body || ''; this.tag = options.tag || ''; this.data = options.data; this.onclick = null; post('oreeNotify', { t: 'show', title: String(title), body: String(options.body || ''), tag: String(options.tag || '') }); }
        close() {} static get permission() { return permission; }
        static requestPermission(cb) { return new Promise((resolve) => { waiting.push((p) => { if (cb) cb(p); resolve(p); }); post('oreeNotify', { t: 'ask' }); }); }
      }
      try { Object.defineProperty(window, 'Notification', { value: OreeNotification, configurable: true, writable: true }); } catch (e) {}
      try { navigator.setAppBadge = (n) => { post('oreeBadge', { n: n === undefined ? 1 : Number(n) }); return Promise.resolve(); }; navigator.clearAppBadge = () => { post('oreeBadge', { n: 0 }); return Promise.resolve(); }; } catch (e) {}
    })();
    """

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if message.name == "oreeBadge" { let n = (body["n"] as? Int) ?? 0; NSApp.dockTile.badgeLabel = n > 0 ? String(n) : nil; return }
        let center = UNUserNotificationCenter.current()
        switch body["t"] as? String {
        case "ask":
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { _ = self.web.evaluateJavaScript("window.__oreeNotifPermission('\(granted ? "granted" : "denied")')") { _, _ in } } }
            }
        case "show":
            let content = UNMutableNotificationContent(); content.title = (body["title"] as? String) ?? info.name; content.body = (body["body"] as? String) ?? ""; content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        default: break
        }
    }

    // MARK: Menus et barre d'outils

    private func buildMenus() {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) { let item = NSMenuItem(); let menu = NSMenu(title: title); items.forEach(menu.addItem); item.submenu = menu; main.addItem(item) }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ flags: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key); i.keyEquivalentModifierMask = flags; i.target = target; return i
        }
        add(info.name, [item("À propos de \(info.name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))), .separator(), item("Masquer \(info.name)", #selector(NSApplication.hide(_:)), "h"), .separator(), item("Quitter \(info.name)", #selector(NSApplication.terminate(_:)), "q")])
        add("Édition", [item("Annuler", Selector(("undo:")), "z"), item("Rétablir", Selector(("redo:")), "z", [.command, .shift]), .separator(), item("Couper", #selector(NSText.cut(_:)), "x"), item("Copier", #selector(NSText.copy(_:)), "c"), item("Coller", #selector(NSText.paste(_:)), "v"), item("Tout sélectionner", #selector(NSText.selectAll(_:)), "a")])
        add("Présentation", [item("Recharger", #selector(reload), "r", target: self), item("Zoom avant", #selector(zoomIn), "+", target: self), item("Zoom arrière", #selector(zoomOut), "-", target: self), item("Taille réelle", #selector(zoomReset), "0", target: self), .separator(), item("Plein écran", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])])
        add("Historique", [item("Précédent", #selector(goBack), "[", target: self), item("Suivant", #selector(goForward), "]", target: self), .separator(), item("Page d'accueil de l'application", #selector(goHome), "h", [.command, .shift], target: self)])
        add("Fenêtre", [item("Fermer (l'application reste prête)", #selector(NSWindow.performClose(_:)), "w"), item("Placer dans le Dock", #selector(NSWindow.performMiniaturize(_:)), "m"), item("Agrandir", #selector(NSWindow.performZoom(_:)))])
        NSApp.mainMenu = main
    }
    @objc func reload() { web.reload() }
    @objc func goBack() { web.goBack() }
    @objc func goForward() { web.goForward() }
    @objc func goHome() { web.load(URLRequest(url: info.startURL)) }
    @objc func zoomIn() { web.pageZoom = min(web.pageZoom + 0.1, 3) }
    @objc func zoomOut() { web.pageZoom = max(web.pageZoom - 0.1, 0.4) }
    @objc func zoomReset() { web.pageZoom = 1 }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("back"), .init("forward"), .flexibleSpace, .init("reload")] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let table: [String: (String, String, Selector)] = ["back": ("chevron.left", "Précédent", #selector(goBack)), "forward": ("chevron.right", "Suivant", #selector(goForward)), "reload": ("arrow.clockwise", "Recharger", #selector(reload))]
        guard let (symbol, label, action) = table[id.rawValue] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id); item.label = label; item.toolTip = label; item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label); item.target = self; item.action = action; return item
    }
}

guard let info = AppInfo.load() ?? (CommandLine.arguments.contains("--selftest") ? AppInfo(id: String(format: "00000000-0000-0000-0000-%012X", (CommandLine.arguments.last ?? "").utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) } % 0xFFFFFFFFFFFF), name: "Essai", startURL: URL(string: CommandLine.arguments.last ?? "https://example.com")!) : nil) else {
    FileHandle.standardError.write(Data("OreeWebApp : Info.plist sans OreeAppID / OreeAppURL\n".utf8)); exit(2)
}
let application = NSApplication.shared
let controller = AppController(info: info)
application.delegate = controller
application.setActivationPolicy(CommandLine.arguments.contains("--selftest") ? .accessory : .regular)
application.run()
