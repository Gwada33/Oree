import AppKit
import WebKit
import SwiftUI
import BrowserCore
import BrowserStorage
import BrowserSettingsUI
import DownloadKit
import OreeObjC
import MediaPlayer

extension BrowserWindowController {

    // MARK: - Navigation

    func load(urlString raw: String, in tab: Tab) {
        guard let resolution = AddressResolver.resolve(raw, defaultEngine: SettingsStore.shared.searchEngine,
                                                       custom: SettingsStore.shared.customSearchShortcuts) else { return }
        let url = resolution.url
        tab.journalNavKind = "typed"
        tab.lastRequestedURL = url
        tab.webView?.load(URLRequest(url: url))
    }

    @objc func openSettings() {
        journalPanel("settings", open: true)
        if settingsWindow == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(
                    onPinnedSitesChanged: { [weak self] in self?.refreshPinnedIcons() },
                    onUpdateFilterLists: { [weak self] in
                        guard let blocker = self?.contentBlocker else { return }
                        Task { await blocker.updateNow() }
                    },
                    onOpenCustomize: { [weak self] in self?.settingsWindow?.close(); self?.openCustomize() },
                    extensions: extensionManager
                )
            )
            let window = NSWindow(contentViewController: hosting)
            window.title = "Réglages"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 800, height: 600))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// ⌘T: opens the palette; whatever you pick or type opens in a new tab.
    /// A URL handed to us by the system: a link clicked in another app, or an .html file.
    public func openExternal(_ url: URL) {
        let isPrivate = SettingsStore.shared.privateByDefault
        if url.isFileURL {
            journalOpenHow = "external"
            let tab = newTab(urlString: nil, isPrivate: isPrivate)
            tab.lastRequestedURL = url
            tab.webView?.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else if url.scheme == "http" || url.scheme == "https" {
            journalOpenHow = "external"
            newTab(urlString: url.absoluteString, isPrivate: isPrivate)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    /// ⌘T — a new tab on the home page with the address field ready to type in.
    @objc func newTabAction() {
        journalOpenHow = "new"
        newTab(urlString: nil, isPrivate: SettingsStore.shared.privateByDefault)
        addressPill.beginEditing(text: "", selectAll: false)
    }

    @objc func newPrivateTabAction() {
        newTab(urlString: nil, isPrivate: true)
    }

    @objc func closeActiveTabAction() {
        if let tab = activeTab { closeTab(tab) }
    }

    @objc func goBack() { activeTab?.webView?.goBack() }
    @objc func goForward() { activeTab?.webView?.goForward() }
    @objc func reloadAction() { activeTab?.webView?.reload() }
    @objc func stopLoadingAction() { activeTab?.webView?.stopLoading() }

    /// Loading indicator: swaps the reload button into a stop button while
    /// the active tab's page is loading, and back again once it settles.
    func updateLoadingIndicator(for tab: Tab) {
        guard tab.id == activeTabID else { return }
        downloads.pageLoading(tab.webView?.isLoading == true)       // downloads yield to the page being loaded
        if tab.showsLoading {
            reloadButton.symbol = "xmark"
            reloadButton.onClick = { [weak self] in self?.stopLoadingAction() }
            reloadButton.setAccessibilityLabel("Arrêter le chargement")
        } else {
            reloadButton.symbol = "arrow.clockwise"
            reloadButton.onClick = { [weak self] in self?.reloadAction() }
            reloadButton.setAccessibilityLabel("Recharger la page")
        }
    }

    /// The user agent for the page about to load: WebKit's own (Safari's) unless the user chose another identity, globally or for this site.
    func applyUserAgent(to webView: WKWebView, for url: URL?) {
        let settings = SettingsStore.shared
        // Le mode responsive impose l'identité de l'appareil montré, quoi que dise le réglage du site.
        if let device = tab(for: webView)?.responsive {
            if webView.customUserAgent != device.userAgent { webView.customUserAgent = device.userAgent }
            if device.userAgent != nil { return }
        }
        let agent = UserAgent.override(mode: settings.userAgentMode, custom: settings.customUserAgent, host: url?.host, chromeHosts: settings.chromeUserAgentHosts,
                                       mobileHosts: settings.mobileSiteHosts)
        if webView.customUserAgent != agent { webView.customUserAgent = agent }
    }

    /// Palette action: ask this site for its mobile version (or the desktop one again), then reload.
    func toggleMobileForCurrentSite() {
        guard let tab = activeTab, let host = tab.webView?.url?.host else { return }
        let settings = SettingsStore.shared
        var hosts = settings.mobileSiteHosts
        if let index = hosts.firstIndex(where: { UserAgent.hostMatches(host, listed: $0) }) { hosts.remove(at: index) } else { hosts.append(host) }
        settings.mobileSiteHosts = hosts
        tab.webView?.reload()
        presentNotice(hosts.contains(where: { UserAgent.hostMatches(host, listed: $0) }) ? "\(host) s’affiche en version mobile." : "\(host) s’affiche en version ordinateur.")
    }

    /// Palette action: present as Chrome on this site (or stop doing so), then reload.
    func toggleChromeAgentForCurrentSite() {
        guard let tab = activeTab, let host = tab.webView?.url?.host else { return }
        let settings = SettingsStore.shared
        var hosts = settings.chromeUserAgentHosts
        if let index = hosts.firstIndex(where: { UserAgent.hostMatches(host, listed: $0) }) { hosts.remove(at: index) } else { hosts.append(host) }
        settings.chromeUserAgentHosts = hosts
        tab.webView?.reload()
        presentNotice(hosts.contains(where: { UserAgent.hostMatches(host, listed: $0) }) ? "\(host) voit Orée comme Chrome." : "\(host) voit Orée comme Safari.")
    }

    /// Shows a popover under `anchor`, or under `fallback` when the anchor is not on screen (a toolbar button the user removed, a window not shown):
    /// AppKit raises an exception for a popover without a place, which used to stop the whole app. Returns false if it could not be shown.
    @discardableResult
    func showPopoverSafely(_ popover: NSPopover, relativeTo anchor: NSView, fallback: NSView? = nil, edge: NSRectEdge = .maxY) -> Bool {
        func usable(_ view: NSView?) -> NSView? {
            guard let view, view.window != nil, !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
            return view
        }
        guard let target = usable(anchor) ?? usable(fallback) else { Log.tabs.error("Popover not shown: no visible place for it"); return false }
        var reason: NSString?
        if OreeShowPopover(popover, target.bounds, target, edge, &reason) { return true }
        Log.tabs.error("Popover refused by AppKit: \((reason as String?) ?? "?", privacy: .public)")
        return false
    }

    /// The notes pad, under the address bar: on the note about this page, or the last one. `append` adds a selection from the page.
    @objc func showNotes() { openNotes(append: nil) }

    func openNotes(append: String?) {
        if let popover = notesPopover, popover.isShown, let view = notesView {
            if let append { view.append(append) } else { popover.close() }
            return
        }
        journalPanel("notes", open: true)
        let url = activeTab?.currentURL.flatMap { $0.scheme == "http" || $0.scheme == "https" ? $0.absoluteString : nil }
        let view = NotesPanelView(repo: noteRepo, pageURL: url, append: append)
        let controller = NSViewController()
        controller.view = view
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
        popover.contentSize = NotesPanelView.size
        notesView = view
        notesPopover = popover
        NotificationCenter.default.addObserver(forName: NSPopover.willCloseNotification, object: popover, queue: .main) { [weak view] _ in
            MainActor.assumeIsolated { view?.saveNow() }
        }
        if showPopoverSafely(popover, relativeTo: addressPill, fallback: window?.contentView, edge: .minY) { DispatchQueue.main.async { view.focusText() } }
    }

    /// The QR code of the page's address, to scan with a phone, with copy and save.
    @objc func showPageQRCode() {
        guard let url = activeTab?.webView?.url, url.scheme == "http" || url.scheme == "https",
              let image = PrivacyTools.qrImage(for: url.absoluteString) else { presentNotice("Cette page n’a pas d’adresse à partager."); return }
        if let popover = qrPopover, popover.isShown { popover.close(); return }
        let view = NSImageView(image: image)
        view.frame = NSRect(x: 0, y: 0, width: 220, height: 220)
        let host = url.host ?? url.absoluteString
        let caption = oreeLabel(host, font: Theme.sans(12), color: Theme.muted)
        caption.alignment = .center
        let copy = TextButton("Copier l’image", style: .secondary, height: 28) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
        }
        let stack = NSStackView(views: [view, caption, copy])
        stack.orientation = .vertical; stack.spacing = 10; stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.frame = NSRect(x: 0, y: 0, width: 252, height: 306)
        let controller = NSViewController(); controller.view = stack
        let popover = NSPopover(); popover.behavior = .transient; popover.contentViewController = controller
        guard showPopoverSafely(popover, relativeTo: addressPill) else { return }
        qrPopover = popover
    }

    func dismissNotice() { noticePill.dismiss() }
    func presentStoppableNotice(_ message: String, button: String, perform: @escaping () -> Void) {
        noticePill.show(message: message, button: button, seconds: 3600, perform: perform)
    }

    func presentNotice(_ message: String) { noticePill.show(message: message, button: "OK", seconds: 6) { } }

    @objc func findInPage() {
        journalPanel("find", open: true)
        findBarContainer?.isHidden = false
        window?.makeFirstResponder(findField)
    }

    @objc func closeFindBar() {
        findBarContainer?.isHidden = true
        activeTab?.webView?.safeRun("window.getSelection().removeAllRanges()", world: .page)
        if let webView = activeTab?.webView {
            window?.makeFirstResponder(webView)
        }
    }

    @objc func findNext() { runFind(backwards: false) }
    @objc func findPrevious() { runFind(backwards: true) }

    func runFind(backwards: Bool) {
        guard let tab = activeTab else { return }
        let term = findField.stringValue
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        guard !term.isEmpty else { return }
        let js = "window.find('\(term)', false, \(backwards), true, false, true, false)"
        tab.webView?.safeRun(js, world: .page)
    }

    @objc func addBookmark() {
        guard let tab = activeTab, let url = tab.webView?.url else { return }
        do {
            try bookmarkRepo.add(url: url.absoluteString, title: tab.displayTitle)
        } catch {
            Log.storage.error("Failed to add bookmark: \(error.localizedDescription)")
        }
        menuBuilder?.refreshBookmarksMenu()
        refreshPinnedIcons()
    }

    /// Favoris › Ajouter tous les onglets aux favoris: every open web page of the current space (private tabs excluded), without duplicates.
    @objc func bookmarkAllTabs() {
        var added = 0
        for tab in visibleTabs() where !tab.isPrivate {
            guard let url = tab.currentURL, url.scheme == "http" || url.scheme == "https", (try? bookmarkRepo.contains(url: url.absoluteString)) == false else { continue }
            if (try? bookmarkRepo.add(url: url.absoluteString, title: tab.displayTitle)) != nil { added += 1 }
        }
        menuBuilder?.refreshBookmarksMenu()
        refreshPinnedIcons()
        presentNotice(added == 0 ? "Tous les onglets sont déjà dans les favoris." : "\(added) onglet\(added > 1 ? "s" : "") ajouté\(added > 1 ? "s" : "") aux favoris.")
    }

    /// Favoris › Exporter les favoris…: a standard bookmarks file (HTML) that Chrome, Safari and Firefox can import.
    @objc func exportBookmarks() {
        guard let window else { return }
        let all = (try? bookmarkRepo.all()) ?? []
        let items = all.map { bookmark -> BookmarkExport.Item in
            let space = bookmark.spaceIndex.flatMap { spaces.indices.contains($0) ? spaces[$0].name : nil } ?? "Tous les espaces"
            return BookmarkExport.Item(title: bookmark.title, url: bookmark.url, folder: space, added: bookmark.createdAt)
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "Favoris Orée.html"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try BookmarkExport.html(items).write(to: url, atomically: true, encoding: .utf8)
                self?.presentNotice("\(items.count) favori\(items.count > 1 ? "s" : "") exporté\(items.count > 1 ? "s" : "").")
            } catch { self?.presentNotice("Impossible d’écrire le fichier : \(error.localizedDescription)") }
        }
    }

    @objc func historyItemClicked(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String, let tab = activeTab else { return }
        load(urlString: urlString, in: tab)
    }

    @objc func bookmarkItemClicked(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String, let tab = activeTab else { return }
        load(urlString: urlString, in: tab)
    }

    func syncToolbar(for tab: Tab) {
        let url = tab.webView?.url ?? tab.currentURL
        addressPill.show(url: (url?.scheme == "http" || url?.scheme == "https") ? url : nil)
        backButton.isEnabled = tab.webView?.canGoBack ?? false
        forwardButton.isEnabled = tab.webView?.canGoForward ?? false
        window?.title = tab.displayTitle + (profileName.map { " — \($0)" } ?? "")
        updateLoadingIndicator(for: tab)
        bindTranslator(of: tab)
    }

    // MARK: - WKNavigationDelegate

    /// Main-frame gatekeeper: URL cleaning, HTTPS-only upgrade, Safe Browsing,
    /// then per-page scripts. Sub-frames and non-web schemes pass straight through.
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.targetFrame?.isMainFrame == true {
            tab(for: webView)?.lastNavigationType = navigationAction.navigationType
            applyUserAgent(to: webView, for: navigationAction.request.url)
            let mobile = SettingsStore.shared.mobileSiteHosts.contains { UserAgent.hostMatches(navigationAction.request.url?.host, listed: $0) }
            preferences.preferredContentMode = mobile ? .mobile : .recommended
        }
        let policy = await decideNavigation(webView, navigationAction, preferences)
        return (policy, preferences)
    }

    func decideNavigation(_ webView: WKWebView, _ navigationAction: WKNavigationAction, _ preferences: WKWebpagePreferences) async -> WKNavigationActionPolicy {
        if let url = navigationAction.request.url, url.scheme == StartPage.actionScheme {
            handleHomeAction(url)
            return .cancel
        }
        if navigationAction.shouldPerformDownload { return .download }
        // A link for another app (mail, phone, a video-call app…): the web view cannot show it, so the system opens it.
        let linkType = navigationAction.navigationType
        let clicked = linkType == .linkActivated || linkType == .formSubmitted
        switch ExternalLinkPolicy.decision(for: navigationAction.request.url, userInitiated: clicked) {
        case .notExternal: break
        case .openDirectly: openExternalLink(navigationAction.request.url, from: webView, ask: false); return .cancel
        case .askFirst: openExternalLink(navigationAction.request.url, from: webView, ask: true); return .cancel
        case .block: presentNotice("Orée n’ouvre pas ce type de lien depuis une page web."); return .cancel
        }
        // ⌥-click on a link: a look at it without leaving the page.
        if linkType == .linkActivated, navigationAction.modifierFlags.contains(.option), let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let tab = tab(for: webView) {
            peek(url, from: tab)
            return .cancel
        }
        guard navigationAction.targetFrame?.isMainFrame == true,
              let original = navigationAction.request.url,
              let scheme = original.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let tab = tab(for: webView) else { return .allow }

        let settings = SettingsStore.shared
        var target = original
        tab.lastRequestedURL = original
        if tab.id == activeTabID { Task { await makeRoom(forNavigationTo: original, in: tab) } }

        // Tracking parameters: only on plain GET loads the user/page started,
        // never on reload / back-forward (those must replay exactly).
        let type = navigationAction.navigationType
        if tab.journalNavKind == "other" {
            switch type { case .linkActivated: tab.journalNavKind = "link"; case .formSubmitted: tab.journalNavKind = "form"; case .reload: tab.journalNavKind = "reload"; case .backForward: tab.journalNavKind = "back"; default: break }
        }
        if settings.urlCleaning, navigationAction.request.httpMethod == "GET", type != .reload, type != .backForward {
            target = urlCleaner.clean(target)
        }

        if target != original {
            webView.load(URLRequest(url: target))
            return .cancel
        }

        // HTTPS-only: WebKit upgrades http:// itself (no cancel-and-reload round
        // trip) and reports a plain failure if the site has no HTTPS, which
        // is where our "continue over HTTP?" screen takes over.
        if case .upgrade(let secure) = HTTPSPolicy(isEnabled: settings.httpsOnly).decision(for: target, exemptHosts: httpExemptHosts) {
            let host = target.host?.lowercased() ?? ""
            // A site that bounces https -> http forever must not trap us in a loop.
            if tab.upgradeAttempts[host, default: 0] < 2 {
                tab.upgradeAttempts[host, default: 0] += 1
                tab.upgradedFromHTTP = target
                if #available(macOS 15.2, *) {
                    preferences.preferredHTTPSNavigationPolicy = .errorOnFailure
                } else {
                    webView.load(URLRequest(url: secure))   // older macOS: cancel and reload over https
                    return .cancel
                }
            }
        } else if #available(macOS 15.2, *) {
            preferences.preferredHTTPSNavigationPolicy = .keepAsRequested
        }

        if let client = safeBrowsing, let host = original.host?.lowercased(), !safeBrowsingBypass.contains(host),
           let threat = await client.check(original) {
            showUnsafeSiteWarning(threat, url: original, in: tab)
            return .cancel
        }

        // Blocking switched off for sites that break when only partly blocked (see ProtectionPolicy).
        let exempt = ProtectionPolicy.isExempt(host: original.host, list: settings.protectionExemptHosts)
        tab.applyContentRuleLists(ruleLists(for: original))
        tab.setUserScripts(userScripts(for: original, isPrivate: tab.isPrivate))
        return .allow
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let tab = tab(for: webView) { updateLoadingIndicator(for: tab); journalNavDone(tab, ok: false, code: (error as NSError).code) }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let tab = tab(for: webView) else { return }
        updateLoadingIndicator(for: tab)
        journalNavDone(tab, ok: false, code: (error as NSError).code)
        tab.tabButton.setTitle(tab.displayTitle, host: tab.badgeHost)
        let nsError = error as NSError
        Log.network.notice("Provisional navigation failed: \(nsError.domain, privacy: .public) \(nsError.code)")
        // Cancellations (we cancelled it ourselves, or a download/redirect took over) aren't failures.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }

        guard let httpURL = tab.upgradedFromHTTP, HTTPSPolicy.shouldOfferHTTPFallback(for: error) else {
            let failedURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
            let host = failedURL?.host ?? failedURL?.absoluteString ?? "cette adresse"
            let goBack: @MainActor () -> Void = { [weak tab] in
                guard let tab else { return }
                tab.interstitial.hide()
                if tab.webView?.canGoBack == true { tab.webView?.goBack() }
            }
            switch LoadFailure.classify(error) {
            case .certificate(let problem):
                tab.interstitial.show(.connectionNotPrivate(host: host, reason: problem.message, goBack: goBack))
            case let failure:
                tab.interstitial.show(.loadFailed(
                    host: host,
                    reason: failure.message,
                    retry: { [weak tab] in
                        guard let tab else { return }
                        tab.interstitial.hide()
                        if let failedURL { tab.webView?.load(URLRequest(url: failedURL)) } else { tab.webView?.reload() }
                    }
                ))
            }
            return
        }
        let host = httpURL.host?.lowercased() ?? ""
        tab.upgradedFromHTTP = nil
        tab.interstitial.show(.httpFallback(
            host: host,
            goBack: { [weak tab] in
                guard let tab else { return }
                tab.interstitial.hide()
                if tab.webView?.canGoBack == true { tab.webView?.goBack() }
            },
            continueOverHTTP: { [weak self, weak tab] in
                guard let self, let tab else { return }
                self.httpExemptHosts.insert(host)
                tab.interstitial.hide()
                tab.webView?.load(URLRequest(url: httpURL))
            }
        ))
    }

    /// Shown in the page, or saved as a download? (The async form is the one WebKit actually matches — the
    /// completion-handler form only "nearly matched" the protocol and was silently never called, so no
    /// download ever started from a response.)
    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        // Files the server marks as attachments (or that WebKit can't display) are downloads, like in Safari.
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
           disposition.hasPrefix("attachment") {
            return .download
        }
        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    /// `<a download>` links and "Save link as…": the engine asks for a download instead of a navigation.
    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        noteNavigation("start", webView)
        updateLoadingIndicator(for: tab)
        if tab.showsLoading { journalNavStart(tab, url: tab.lastRequestedURL ?? webView.url) }
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        noteNavigation("commit", webView)
        journalNavCommit(tab)
        applySiteZoom(to: webView)
        tab.interstitial.hide()
        tab.pageDidCommit()
        refreshNowPlaying()        // a new page: whatever the old one played is over
        // A reload keeps the pop-up; another page takes it away.
        if tab.id == activeTabID, digestPanel.state != "closed", ResumePolicy.key(for: webView.url) != digestKey { digestPanel.close() }
        tab.revealWebView()
        if !firstCommitTraced { firstCommitTraced = true; LaunchTrace.mark("first page committed") }
        extensionManager.tabChanged(tab, [.URL, .loading, .title])
        tab.tabButton.setTitle(tab.displayTitle, host: tab.badgeHost)
        if tab.id == activeTabID {
            syncToolbar(for: tab)
        }
    }

    /// The WebContent process backing this tab's page crashed (OOM, bug,
    /// etc). The tab itself is unaffected — show a "Recharger" screen in
    /// place of the dead page instead of closing the tab or reloading
    /// automatically (which could loop forever if the page itself is what's
    /// crashing the process).
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        Log.tabs.error("WebContent process terminated for tab \(tab.id.uuidString, privacy: .public)")
        tab.interstitial.show(.crashed { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.recoverFromCrash(tab)
        })
    }

    /// La mémoire ambiante : une page restée ouverte et visible une douzaine de secondes est considérée comme lue ; on en garde un extrait (voir `PageMemoryPolicy`).
    func scheduleMemoryCapture(for tab: Tab) {
        guard SettingsStore.shared.ambientMemory, !tab.isPrivate else { return }
        memoryCaptureTasks[tab.id]?.cancel()
        let address = tab.currentURL
        memoryCaptureTasks[tab.id] = Task { @MainActor [weak self, weak tab] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, let tab, tab.currentURL == address, tab.id == self.activeTab?.id, let web = tab.webView,
                  let json = await web.safeEvaluate(PageMemoryScript.source, world: PageMemoryScript.world) as? String,
                  let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return }
            let page = PageMemoryPolicy.memorable(url: address, title: (object["title"] as? String) ?? tab.displayTitle, text: (object["text"] as? String) ?? "", isPrivate: tab.isPrivate,
                                                  hasSecretField: (object["secret"] as? Bool) ?? true, exemptHosts: SettingsStore.shared.protectionExemptHosts)
            guard let page, let host = page.url.host else { return }
            try? self.pageMemory.remember(url: page.url.absoluteString, host: host, title: page.title, text: page.text)
            try? self.pageMemory.purge(olderThanDays: SettingsStore.shared.ambientMemoryDays)
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let tab = tab(for: webView) { scheduleMemoryCapture(for: tab) }
        guard let tab = tab(for: webView) else { return }
        journalNavDone(tab, ok: true)
        tab.tabButton.setTitle(tab.displayTitle, host: tab.badgeHost)
        clearWakeRevealIfNeeded(for: tab)
        tab.restorePageStateIfNeeded()
        tab.revealWebView()
        extensionManager.tabChanged(tab, [.loading, .title])
        offerWebStoreInstall(for: tab)
        tab.upgradedFromHTTP = nil
        tab.upgradeAttempts = [:]
        if let url = webView.url, url.absoluteString != "about:blank", url.scheme != "oree", !tab.isPrivate {
            do {
                try historyRepo.recordVisit(url: url.absoluteString, title: tab.displayTitle)
                SpotlightIndexer.shared.add(url: url.absoluteString, title: tab.displayTitle)
            } catch {
                Log.storage.error("Failed to record history visit: \(error.localizedDescription)")
            }
            menuBuilder?.refreshHistoryMenu()
        }
        if tab.id == activeTabID {
            syncToolbar(for: tab)    // also recognizes the page language for the translate button
            offerResume(for: tab)
            probeDigest(for: tab)
        }
        saveSession()
    }

    // MARK: - WKUIDelegate (permissions)

    public func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        let kinds: [SitePermission]
        switch type {
        case .camera: kinds = [.camera]
        case .microphone: kinds = [.microphone]
        default: kinds = [.camera, .microphone]
        }
        return await decidePermission(kinds, origin: origin, webView: webView)
    }

    // Geolocation permission prompts only exist in the macOS 27 WebKit API.
    @available(macOS 27.0, *)
    public func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo) async -> WKPermissionDecision {
        await decidePermission([.location], origin: origin, webView: webView)
    }

    // MARK: - WKUIDelegate (popups open as tabs)

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let isPrivate = tab(for: webView)?.isPrivate ?? false
        let newTab = Tab(configuration: configuration, isPrivate: isPrivate)
        newTab.spaceIndex = tab(for: webView)?.spaceIndex ?? currentSpace
        journalOpenHow = "link"
        attachTab(newTab)
        selectTab(newTab)
        return newTab.webView
    }

    // MARK: - WKDownloadDelegate

    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let isPrivate = !(download.webView?.configuration.websiteDataStore.isPersistent ?? true)
        return await downloads.handle(download, response: response, suggestedFilename: suggestedFilename,
                                      pageURL: download.webView?.url, isPrivate: isPrivate)
    }

    public func downloadDidFinish(_ download: WKDownload) { downloads.webkitFinished(download) }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        Log.network.error("Download failed: \(error.localizedDescription, privacy: .public)")
        downloads.webkitFailed(download, error: error, resumeData: resumeData)
    }
}

// MARK: Gestes de souris
extension BrowserWindowController {
    /// Ce que fait chaque geste (voir `MouseGesture.bindings`).
    func performMouseGesture(_ action: MouseGesture.Action) {
        guard let tab = activeTab else { return }
        switch action {
        case .back: if tab.webView?.canGoBack == true { tab.webView?.goBack() }
        case .forward: if tab.webView?.canGoForward == true { tab.webView?.goForward() }
        case .newTab: journalOpenHow = "new"; newTab(urlString: nil, isPrivate: SettingsStore.shared.privateByDefault); addressPill.beginEditing(text: "", selectAll: false)
        case .closeTab: closeTab(tab)
        case .reload: tab.webView?.reload()
        case .scrollTop: Task { _ = await tab.webView?.safeEvaluate("window.scrollTo({ top: 0, behavior: 'smooth' })", world: .page) }
        case .scrollBottom: Task { _ = await tab.webView?.safeEvaluate("window.scrollTo({ top: document.documentElement.scrollHeight, behavior: 'smooth' })", world: .page) }
        case .previousTab, .nextTab:
            let list = visibleTabs()
            guard let index = list.firstIndex(where: { $0.id == tab.id }), list.count > 1 else { return }
            journalSelectVia = "keyboard"
            selectTab(list[(index + (action == .nextTab ? 1 : list.count - 1)) % list.count])
        case .reopenTab: reopenClosedTab()
        }
    }
}
