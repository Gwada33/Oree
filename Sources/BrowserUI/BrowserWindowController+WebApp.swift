import AppKit
import WebKit
import BrowserCore

/// Applications : un site qui devient une application. Sa fenêtre n'a ni onglets, ni barre latérale, ni barre d'adresse (juste précédent, suivant, recharger) ;
/// un lien vers un autre site s'ouvre dans le navigateur. Un raccourci « Nom.app » (dans ~/Applications) la lance depuis le Dock, Spotlight ou Launchpad.
extension BrowserWindowController {
    var webAppStore: WebAppStore { WebAppStore() }

    /// Où ranger les raccourcis (~/Applications ; un dossier d'essai pour les tests).
    private var shortcutsFolder: URL {
        ProcessInfo.processInfo.environment["HB_WEBAPPS_APPLICATIONS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    }

    func shortcutURL(for app: WebApp) -> URL { shortcutsFolder.appendingPathComponent(WebAppShortcut.folderName(for: app.name), isDirectory: true) }

    // MARK: Fenêtre d'application

    /// Ouvre la fenêtre de l'application (ou ramène celle qui est ouverte).
    func openWebApp(_ app: WebApp) {
        if app.standalone {      // une application indépendante est un programme à elle : on la lance
            let bundle = shortcutURL(for: app)
            if FileManager.default.fileExists(atPath: bundle.path) { NSWorkspace.shared.openApplication(at: bundle, configuration: NSWorkspace.OpenConfiguration()); return }
        }
        if let open = NSApp.windows.compactMap({ $0.windowController as? BrowserWindowController }).first(where: { $0.webApp?.id == app.id }) {
            open.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        guard let other = Self.newWindowHandler?(false) else { NSSound.beep(); return }
        other.becomeWebApp(app)
        NSApp.activate(ignoringOtherApps: true)
    }

    func becomeWebApp(_ app: WebApp) {
        webApp = app
        guard let window else { return }
        window.title = app.name
        window.minSize = NSSize(width: 420, height: 320)
        window.setFrameAutosaveName("OreeApp-\(app.id)")
        if !window.setFrameUsingName("OreeApp-\(app.id)") { window.setContentSize(NSSize(width: 1100, height: 760)); window.center() }
        addressPill.isHidden = true
        applySidebarMode(animated: false)
        applyChromeLayout()
        allowAppTab = true
        newTab(urlString: app.startURL, isPrivate: false)
        allowAppTab = false
        let id = app.id
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            DistributedNotificationCenter.default().postNotificationName(Notification.Name(WebAppShortcut.closedNotification), object: id, userInfo: nil, deliverImmediately: true)
        }
    }

    /// Un lien activé vers un autre site : il s'ouvre dans la fenêtre principale du navigateur, pas dans l'application.
    func webAppSendsOut(_ url: URL?) -> Bool {
        guard let app = webApp, let url, url.scheme == "http" || url.scheme == "https", !WebAppScope.contains(url, in: app) else { return false }
        if let main = NSApp.windows.compactMap({ $0.windowController as? BrowserWindowController }).first(where: { !$0.isSecondary && $0.webApp == nil }) {
            main.newTab(urlString: url.absoluteString, isPrivate: false); main.window?.makeKeyAndOrderFront(nil)
        } else { NSWorkspace.shared.open(url) }
        return true
    }

    /// Le menu / la palette de la fenêtre d'une application n'ont pas d'onglets à ouvrir : ils vont dans la fenêtre principale.
    func newTabForApp(_ urlString: String?, isPrivate: Bool) -> Tab? {
        guard webApp != nil, !allowAppTab else { return nil }
        guard let main = NSApp.windows.compactMap({ $0.windowController as? BrowserWindowController }).first(where: { !$0.isSecondary && $0.webApp == nil }) else { return nil }
        let tab = main.newTab(urlString: urlString, isPrivate: isPrivate)
        main.window?.makeKeyAndOrderFront(nil)
        return tab
    }

    // MARK: Installer

    @objc func installWebAppAction() {
        guard webApp == nil, let tab = activeTab, !tab.isPrivate, let url = tab.currentURL, url.scheme == "http" || url.scheme == "https" else {
            presentNotice("Ouvrez d'abord un site (hors navigation privée) pour l'installer comme application."); return
        }
        if let existing = webAppStore.app(forHost: url.host) { openWebApp(existing); return }
        Task { @MainActor in await self.installWebApp(from: tab, url: url) }
    }

    /// Ce que la page dit d'elle-même : son nom et ses icônes (balises <link>, manifeste).
    private func pageIdentity(of tab: Tab) async -> (name: String, icons: [URL]) {
        guard let web = tab.webView else { return ("", []) }
        let script = """
        (async () => {
          const abs = (h) => { try { return new URL(h, location.href).href; } catch (e) { return null; } };
          const meta = (n) => (document.querySelector('meta[property="' + n + '"],meta[name="' + n + '"]') || {}).content || '';
          let name = meta('application-name') || meta('og:site_name') || '';
          const icons = [];
          const size = (l) => Math.max(...String(l.getAttribute('sizes') || '0').split(' ').map((s) => parseInt(s) || 0));
          for (const l of document.querySelectorAll('link[rel~="apple-touch-icon"],link[rel~="icon"],link[rel="shortcut icon"]')) icons.push({ href: abs(l.getAttribute('href')), size: l.rel.includes('apple') ? 180 : size(l) });
          const m = document.querySelector('link[rel="manifest"]');
          if (m) { try { const j = await (await fetch(abs(m.getAttribute('href')))).json(); name = j.short_name || j.name || name; for (const i of j.icons || []) icons.push({ href: new URL(i.src, abs(m.getAttribute('href'))).href, size: Math.max(...String(i.sizes || '0').split(' ').map((s) => parseInt(s) || 0)) }); } catch (e) {} }
          icons.push({ href: location.origin + '/favicon.ico', size: 1 });
          return JSON.stringify({ name: name || document.title || '', icons: icons.filter((i) => i.href).sort((a, b) => b.size - a.size).map((i) => i.href) });
        })()
        """
        guard let raw = try? await web.callAsyncJavaScript("return await \(script);", arguments: [:], in: nil, contentWorld: .page) as? String, let data = raw.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ("", []) }
        return ((json["name"] as? String) ?? "", ((json["icons"] as? [String]) ?? []).compactMap(URL.init(string:)))
    }

    private func downloadIcon(from candidates: [URL]) async -> NSImage? {
        for url in candidates.prefix(5) {
            guard let (data, response) = try? await URLSession.shared.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200, data.count > 100, data.count < 5_000_000,
                  let image = NSImage(data: data), image.size.width >= 16 else { continue }
            return image
        }
        return nil
    }

    func installWebApp(from tab: Tab, url: URL) async {
        let identity = await pageIdentity(of: tab)
        let host = url.host ?? "site"
        var suggested = identity.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if suggested.count > 40 || suggested.isEmpty { suggested = WebAppScope.suggestedName(host: host) }
        var name = ProcessInfo.processInfo.environment["HB_WEBAPPS_AUTOCONFIRM_NAME"] ?? suggested, makeShortcut = true
        var standalone = ProcessInfo.processInfo.environment["HB_WEBAPPS_MODE"] != "oree"
        if ProcessInfo.processInfo.environment["HB_WEBAPPS_AUTOCONFIRM"] == nil {
            guard let window else { return }
            let alert = NSAlert()
            alert.messageText = "Installer « \(host) » comme application ?"
            alert.informativeText = "Le site s'ouvrira dans sa propre fenêtre, sans onglets, avec son icône. Les liens vers d'autres sites s'ouvriront dans Orée."
            let field = NSTextField(string: suggested); field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
            let mode = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
            mode.addItems(withTitles: ["Application indépendante (n'a pas besoin d'Orée, ses propres données)", "Fenêtre d'Orée (tes extensions, ta session)"])
            let box = NSButton(checkboxWithTitle: "Ajouter un raccourci dans Applications (Dock, Spotlight)", target: nil, action: nil); box.state = .on
            let stack = NSStackView(views: [field, mode, box]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8; stack.frame = NSRect(x: 0, y: 0, width: 340, height: 92)
            alert.accessoryView = stack
            alert.addButton(withTitle: "Installer"); alert.addButton(withTitle: "Annuler")
            let agreed = await withCheckedContinuation { c in alert.beginSheetModal(for: window) { c.resume(returning: $0 == .alertFirstButtonReturn) } }
            guard agreed else { return }
            name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); makeShortcut = box.state == .on; standalone = mode.indexOfSelectedItem == 0
        }
        if name.isEmpty { name = suggested }
        let source = await downloadIcon(from: identity.icons)
        let app = WebApp(name: name, startURL: url.absoluteString, standalone: standalone)
        if standalone { makeShortcut = true }      // une application indépendante, c'est son raccourci
        let icon = WebAppIcon.render(source: source, name: name)
        do {
            try webAppStore.add(app)
            if let png = WebAppIcon.png(icon) { try? png.write(to: webAppStore.iconURL(for: app.id)) }
        } catch { presentNotice("Installation impossible : \(error.localizedDescription)"); return }
        var message = "« \(app.name) » est installée."
        if makeShortcut {
            if let created = await createShortcut(for: app, icon: icon) { message += " Raccourci : \(created.deletingLastPathComponent().lastPathComponent)/\(created.lastPathComponent)." }
            else { message += " (Le raccourci n'a pas pu être créé.)" }
        }
        presentNotice(message)
        openWebApp(app)
    }

    // MARK: Raccourci macOS (Nom.app)

    @discardableResult
    func createShortcut(for app: WebApp, icon: NSImage) async -> URL? {
        let fm = FileManager.default
        let executable = app.standalone ? "OreeWebApp" : "OreeAppLauncher"
        guard let launcher = Bundle.main.resourceURL?.appendingPathComponent("WebAppLauncher/\(executable)"), fm.fileExists(atPath: launcher.path) else { return nil }
        let exported = app.standalone ? await contentBlocker.exportForStandaloneApp(startURL: URL(string: app.startURL)!) : (rules: [String](), cosmetic: "")
        let bundle = shortcutURL(for: app)
        do {
            try? fm.removeItem(at: bundle)
            try fm.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try fm.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            try fm.copyItem(at: launcher, to: bundle.appendingPathComponent("Contents/MacOS/\(executable)"))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.appendingPathComponent("Contents/MacOS/\(executable)").path)
            for (index, json) in exported.rules.enumerated() { try json.write(to: bundle.appendingPathComponent("Contents/Resources/rules-\(index).json"), atomically: true, encoding: .utf8) }
            try exported.cosmetic.write(to: bundle.appendingPathComponent("Contents/Resources/cosmetic.css"), atomically: true, encoding: .utf8)
            try WebAppShortcut.infoPlist(for: app, oreePath: Bundle.main.bundleURL.path).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            _ = WebAppIcon.writeICNS(from: icon, to: bundle.appendingPathComponent("Contents/Resources/AppIcon.icns"))
            let sign = Process(); sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign"); sign.arguments = ["--force", "--sign", "-", bundle.path]
            sign.standardError = FileHandle.nullDevice; sign.standardOutput = FileHandle.nullDevice
            try? sign.run(); sign.waitUntilExit()
            NSWorkspace.shared.noteFileSystemChanged(bundle.path)
            return bundle
        } catch { return nil }
    }

    // MARK: Retirer / lister

    func removeWebApp(_ app: WebApp) {
        for open in NSApp.windows.compactMap({ $0.windowController as? BrowserWindowController }) where open.webApp?.id == app.id { open.window?.close() }
        try? webAppStore.remove(id: app.id)
        try? FileManager.default.removeItem(at: shortcutURL(for: app))
        presentNotice("L'application « \(app.name) » est retirée.")
    }

    func webAppActions() -> [(String, String, @MainActor (BrowserWindowController) -> Void)] {
        var items: [(String, String, @MainActor (BrowserWindowController) -> Void)] = []
        if webApp == nil, let url = activeTab?.currentURL, url.scheme == "http" || url.scheme == "https", webAppStore.app(forHost: url.host) == nil {
            items.append(("Installer ce site comme application…", "square.and.arrow.down.on.square", { $0.installWebAppAction() }))
        }
        let apps = webAppStore.all()
        for app in apps { items.append(("Ouvrir l'application « \(app.name) »", "macwindow", { $0.openWebApp(app) })) }
        for app in apps { items.append(("Retirer l'application « \(app.name) »", "trash", { $0.removeWebApp(app) })) }
        return items
    }
}

extension WebAppScope {
    /// Un nom lisible pour un site : « www.youtube.com » → « Youtube ».
    public static func suggestedName(host: String) -> String {
        let parts = normalized(host).split(separator: ".").map(String.init)
        let core = parts.count >= 2 ? parts[parts.count - 2] : (parts.first ?? host)
        return core.prefix(1).uppercased() + core.dropFirst()
    }
}
