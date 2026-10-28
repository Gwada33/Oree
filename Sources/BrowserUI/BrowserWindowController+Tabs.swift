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

    // MARK: - Tab lifecycle

    func makeConfiguration(isPrivate: Bool) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = isPrivate ? privateProcessPool : processPool
        config.websiteDataStore = isPrivate ? .nonPersistent() : ProfileContext.dataStore
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.applicationNameForUserAgent = UserAgent.applicationName   // announce as Safari: sites serve their current pages
        WebKitTuning.applyFeatures(to: config.preferences)
        WebKitTuning.applyConfiguration(to: config)
        // Off by default in WKWebView: without it, the fullscreen button on
        // videos (YouTube, etc.) and the Fullscreen API do nothing.
        config.preferences.isElementFullscreenEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = SettingsStore.shared.autoplayMediaAllowed ? [] : .all
        config.allowsAirPlayForMediaPlayback = true
        if SettingsStore.shared.adBlockEnabled {
            contentBlocker.ruleLists.forEach { config.userContentController.add($0) }
        }
        if SettingsStore.shared.fingerprintProtection {
            config.userContentController.addUserScript(FingerprintProtection.makeUserScript(sessionSeed: fingerprintSeed))
        }
        config.userContentController.addUserScript(CredentialScript.makeUserScript())
        config.userContentController.addUserScript(AutofillScript.makeUserScript())
        config.userContentController.addUserScript(MediaScript.makeUserScript())
        if SettingsStore.shared.eventJournalEnabled, !isPrivate { config.userContentController.addUserScript(JournalScript.makeUserScript()) }
        if !isPrivate { config.userContentController.addUserScript(HoverPreconnectScript.makeUserScript()) }
        if SettingsStore.shared.autoRejectCookieBanners { config.userContentController.addUserScript(CookieBannerScript.makeUserScript()) }
        if SettingsStore.shared.sendGlobalPrivacyControl { config.userContentController.addUserScript(PrivacyTools.gpcUserScript()) }
        config.preferences.minimumFontSize = CGFloat(SettingsStore.shared.minimumFontSize)
        if SettingsStore.shared.resumeEnabled { config.userContentController.addUserScript(ResumeScript.makeUserScript()) }
        config.userContentController.addUserScript(BoostScript.makeUserScript(boostConfig()))
        if SettingsStore.shared.lightLongPages {
            config.userContentController.addUserScript(LongPageScript.makeUserScript())
        }
        config.userContentController.add(credentialHandler, name: CredentialScript.handlerName)
        config.setURLSchemeHandler(oreeSchemeHandler, forURLScheme: "oree")
        // Extensions run in normal tabs only, never in private ones.
        if !isPrivate { config.webExtensionController = extensionManager.controller }
        return config
    }

    func attachTab(_ tab: Tab) {
        tab.owner = self
        tab.webView?.navigationDelegate = self
        tab.webView?.uiDelegate = self
        // Weak: Tab owns its button, so a strong capture here is a retain cycle that
        // keeps every closed tab (and its playing video) alive forever.
        tab.tabButton.onSelect = { [weak self, weak tab] in if let tab { self?.journalSelectVia = "click"; self?.selectTab(tab) } }
        tab.tabButton.onHoverEnd = { [weak self, weak tab] dwell, previewed, clicked in if let tab { self?.journalTabHover(tab, dwell: dwell, preview: previewed, clicked: clicked) } }
        tab.tabButton.onClose = { [weak self, weak tab] in if let tab { self?.closeTab(tab) } }
        tab.tabButton.onReorder = { [weak self, weak tab] steps in
            guard let self, let tab else { return }
            self.moveTab(tab, by: steps)
        }
        tab.tabButton.contextMenuProvider = { [weak self, weak tab] in
            guard let self, let tab else { return nil }
            return self.makeTabMenu(for: tab)
        }
        tab.tabButton.onToggleMute = { [weak self, weak tab] in
            tab?.toggleMute()
            self?.refreshAudioIndicators()
        }
        tab.tabButton.setTitle(tab.displayTitle, host: tab.badgeHost)

        tabs.append(tab)
        journalTabOpened(tab)
        contentContainer.addSubview(tab.contentSlot, positioned: .below, relativeTo: loadingBar)
        tab.onTitleChange = { [weak self, weak tab] in
            guard let tab else { return }
            tab.tabButton.setTitle(tab.displayTitle, host: tab.badgeHost)
            if self?.effectiveSidebarMode == .compact { self?.updateTabCount() }
            self?.extensionManager.tabChanged(tab, .title)
            self?.refreshWidgets()
        }
        tab.ghostRuleLists = { [weak self, weak tab] in self?.ruleLists(for: tab?.currentURL) ?? [] }
        tab.onURLChange = { [weak self, weak tab] in
            guard let self, let tab else { return }
            tab.tabButton.setTitle(tab.displayTitle, host: tab.badgeHost)
            if tab.id == self.activeTabID { self.syncToolbar(for: tab) }
        }
        tab.onSleepChange = { [weak self, weak tab] _ in
            guard let self, let tab else { return }
            tab.tabButton.setSleeping(tab.isSuspended)
            self.updateTabCount()
        }
        tab.tabButton.setSleeping(tab.isSuspended)
        tab.onFreezeChange = { [weak self, weak tab] _ in
            guard let self, let tab else { return }
            tab.tabButton.setFrozen(tab.isFrozen)
            self.updateTabCount()
        }
        tab.tabButton.onHoverPreview = { [weak self, weak tab] hovering in
            guard let self, let tab else { return }
            if hovering { self.showTabPreview(for: tab) } else { self.hideTabPreview(of: tab) }
        }
        tab.tabButton.onHoverDwell = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.prewake(tab)
        }
        tab.onProgress = { [weak self, weak tab] progress, isLoading in
            guard let self, let tab else { return }
            let hue = self.spaces[min(tab.spaceIndex, self.spaces.count - 1)].hue
            tab.tabButton.setLoading(isLoading, hue: hue)
            guard tab.id == self.activeTabID else { return }
            self.loadingBar.update(progress: progress, isLoading: isLoading)
        }
        tab.slotTop = tab.contentSlot.topAnchor.constraint(equalTo: contentContainer.topAnchor)
        tab.slotLeading = tab.contentSlot.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor)
        tab.slotTrailing = tab.contentSlot.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor)
        tab.slotBottom = tab.contentSlot.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        NSLayoutConstraint.activate([tab.slotTop!, tab.slotLeading!, tab.slotTrailing!, tab.slotBottom!])
        tab.contentSlot.isHidden = true
        rebuildTabList()
        if tab.spaceIndex == currentSpace { tab.tabButton.animateIn() }
        extensionManager.tabOpened(tab)
    }

    /// Reloading after `webViewWebContentProcessDidTerminate` respawns a
    /// fresh WebContent process for the same `WKWebView` instance — the tab,
    /// its back-forward history and the rest of the app are untouched.
    func recoverFromCrash(_ tab: Tab) {
        tab.interstitial.hide()
        if let url = tab.webView?.url {
            tab.webView?.load(URLRequest(url: url))
        } else {
            tab.webView?.reload()
        }
    }

    /// Ouvre une page d'extension (webkit-extension://…) telle quelle : la barre d'adresse la prendrait pour une recherche.
    @discardableResult
    func newTab(extensionPage url: URL, context: WKWebExtensionContext) -> Tab {
        // Une page d'extension ne se charge que dans une vue configurée par son contexte (sinon : erreur -1008, page introuvable).
        let tab = newTab(urlString: nil, isPrivate: false, configuration: context.webViewConfiguration)
        tab.lastRequestedURL = url
        tab.webView?.load(URLRequest(url: url))
        return tab
    }

    @discardableResult
    func newTab(urlString: String?, isPrivate: Bool, configuration: WKWebViewConfiguration? = nil) -> Tab {
        let config = configuration ?? makeConfiguration(isPrivate: isPrivate)
        LaunchTrace.mark("newTab: configuration made")
        let tab = Tab(configuration: config, isPrivate: isPrivate)
        LaunchTrace.mark("newTab: tab + web view created")
        tab.spaceIndex = currentSpace
        attachTab(tab)
        LaunchTrace.mark("newTab: attached")
        let homepage = SettingsStore.shared.customHomepageURL
        if let urlString {
            load(urlString: urlString, in: tab)
        } else if !homepage.isEmpty {
            load(urlString: homepage, in: tab)
        } else {
            let input = homeInput(for: tab)
            LaunchTrace.mark("newTab: home data read")
            let html = StartPage.render(input)
            LaunchTrace.mark("newTab: home html rendered")
            tab.webView?.loadHTMLString(html, baseURL: StartPage.baseURL)
        }
        selectTab(tab)
        LaunchTrace.mark("newTab: selected")
        saveSession()
        return tab
    }

    /// Everything the home page shows, for a tab in the current space.
    func homeInput(for tab: Tab) -> HomeInput {
        let recent = (tab.isPrivate || !SettingsStore.shared.startPageShowsRecent) ? [] : ((try? historyRepo.recent(limit: 6)) ?? [])
        let chips = spaces.enumerated().map { index, space in
            HomeInput.SpaceChip(index: index, name: space.name, hue: space.hue, icon: space.icon,
                                tabCount: tabs.filter { $0.spaceIndex == index }.count)
        }
        return HomeInput(hue: SettingsStore.shared.accentHue,   // l'accent choisi, comme la barre et les réglages ; les puces d'espaces gardent leur propre teinte
                         favorites: (try? bookmarkRepo.all(forSpace: tab.spaceIndex)) ?? [],
                         recent: recent, spaces: chips)
    }

    /// Links of the home page that ask the app to do something (oree-action://…).
    func handleHomeAction(_ url: URL) {
        switch url.host {
        case "space": if let index = Int(url.lastPathComponent) { selectSpace(index) }
        case "customize": openSettings()
        default: break
        }
    }

    /// The card under the pointer: a picture of the page, its title and site, and its state or memory. Never for the tab in front.
    func showTabPreview(for tab: Tab) {
        guard SettingsStore.shared.tabPreviews, tab.id != activeTabID, window?.isKeyWindow == true || ProcessInfo.processInfo.environment["HB_FRESH_SESSION"] != nil else { return }
        tabPreviewTask?.cancel()
        tabPreviewTask = Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            let image = await tab.previewImage()
            guard !Task.isCancelled, tab.tabButton.window != nil, tab.id != self.activeTabID else { return }
            let row = self.taskManagerSnapshot().snapshot.rows.first { $0.id == tab.id }
            let status: String
            switch row?.state {
            case .sleeping?: status = "En veille"
            case .frozen?: status = "Figé · " + TaskManagerRows.memory(row?.bytes ?? 0)
            case .audio?: status = "Joue du son · " + TaskManagerRows.memory(row?.bytes ?? 0)
            case .some(let state) where (row?.bytes ?? 0) > 0: status = state.rawValue + " · " + TaskManagerRows.memory(row?.bytes ?? 0)
            default: status = ""
            }
            self.tabPreviewPopover?.close()
            let controller = NSViewController()
            controller.view = TabPreviewCard(image: image, title: tab.displayTitle, host: tab.badgeHost, status: status)
            let popover = NSPopover()
            popover.behavior = .applicationDefined; popover.animates = false; popover.contentViewController = controller
            let horizontal = SettingsStore.shared.tabLayout == .horizontal
            if self.showPopoverSafely(popover, relativeTo: tab.tabButton, edge: horizontal ? .minY : .maxX) { self.tabPreviewPopover = popover }
        }
    }

    func hideTabPreview(of tab: Tab? = nil) {
        tabPreviewTask?.cancel()
        tabPreviewPopover?.close()
        tabPreviewPopover = nil
    }

    /// ⌃Tab — back to the tab used before this one (again: back to this one).
    @objc func selectRecentTab() {
        guard let previous = recentTabIDs.dropFirst().compactMap({ id in tabs.first { $0.id == id } }).first else { NSSound.beep(); return }
        selectTab(previous)
    }

    func selectTab(_ tab: Tab) {
        recentTabIDs.removeAll { $0 == tab.id }
        recentTabIDs.insert(tab.id, at: 0)
        if recentTabIDs.count > 50 { recentTabIDs.removeLast() }
        aiBarController?.tabChanged(id: tab.id, title: tab.displayTitle)
        if peekPanel.isShown { peekPanel.close() }
        if digestPanel.state != "closed" { digestPanel.close() }     // the essentials belong to the page they were made from
        // Picking a tab that isn't one of the two sides leaves the split screen.
        if let pair = splitPair, tab.id != pair.left, tab.id != pair.right { endSplit(keeping: tab.id) }
        if tab.spaceIndex != currentSpace { setCurrentSpace(tab.spaceIndex, animated: true) }
        lastActiveTabInSpace[tab.spaceIndex] = tab.id
        if let gid = tab.groupID, let gi = groups.firstIndex(where: { $0.id == gid }), groups[gi].collapsed {
            groups[gi].collapsed = false
            rebuildTabList()
        }
        let previouslyActive = activeTab
        if let previous = activeTab, previous.id != tab.id {
            previous.tabButton.isActive = false
            previous.contentSlot.isHidden = !splitContains(previous.id)
            previous.lastActiveDate = Date()
            // Snapshot now, while the page is exactly as the user saw it — sleeping later then costs nothing.
            Task { await previous.captureSnapshot() }
        }
        let switching = activeTabID != nil && activeTabID != tab.id
        activeTabID = tab.id
        tab.contentSlot.isHidden = false
        tab.tabButton.isActive = true
        journalTabSelected(tab, previous: previouslyActive)
        syncResponsiveBar()
        if SettingsStore.shared.tabLayout == .horizontal, tab.tabButton.superview === tabStrip.tabsStack { tabStrip.activeTabView = tab.tabButton; tabStrip.needsLayout = true }
        if switching {
            tab.contentSlot.alphaValue = 0
            Motion.animate(Motion.quick) { tab.contentSlot.animator().alphaValue = 1 }
        }

        ensureAwake(tab)

        syncToolbar(for: tab)
        refreshSplitHeaders()
        updateTabCount()
        if previouslyActive?.id != tab.id { extensionManager.tabActivated(tab, previous: previouslyActive) }
        refreshExtensionToolbar()
        loadingBar.update(progress: tab.showsLoading ? (tab.webView?.estimatedProgress ?? 0) : 0, isLoading: tab.showsLoading)
        if let webView = tab.webView {
            window?.makeFirstResponder(webView)
        }
    }

    func closeTab(_ tab: Tab, remember: Bool = true) {
        aiBarController?.tabClosed(tab.id)
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if let pair = splitPair, tab.id == pair.left || tab.id == pair.right {
            endSplit(keeping: tab.id == pair.left ? pair.right : pair.left)
        }
        journalTabClosed(tab)
        extensionManager.tabClosed(tab)
        if remember, !tab.isPrivate, let url = tab.currentURL {
            closedTabs.append((url, tab.currentInteractionState, tab.displayTitle, tab.spaceIndex))
            if closedTabs.count > 20 { closedTabs.removeFirst() }
        }
        tab.contentSlot.removeFromSuperview()
        tab.tearDown()
        tabs.remove(at: idx)
        updateTabCount()
        let button = tab.tabButton
        // The rows below spring up into the gap once the closed row has gone.
        let container = button.superview as? NSStackView
        button.animateOut { [weak self] in
            guard let self else { return }
            let before = TabMotion.visualFrames(of: container?.arrangedSubviews ?? [])
            self.rebuildTabList()
            button.removeFromSuperview()
            container?.layoutSubtreeIfNeeded()
            self.tabStrip.layoutSubtreeIfNeeded()
            TabMotion.reflow(container?.arrangedSubviews ?? [], from: before)
        }
        saveSession()

        if tabs.isEmpty {
            window?.close()
            return
        }
        if activeTabID == tab.id {
            // The closest tab in the same space; if that space is now empty, open a fresh one in it.
            if let next = TabSelection.neighbor(afterRemovingIndex: idx, spaces: tabs.map(\.spaceIndex), space: tab.spaceIndex) {
                journalSelectVia = "close"
                selectTab(tabs[next])
            } else {
                newTab(urlString: nil, isPrivate: SettingsStore.shared.privateByDefault)
            }
        }
    }

    /// Moves the active tab one slot up/down in both the model array and the
    /// sidebar's stack view — the "réordonner" requirement. Drag-and-drop in
    /// the sidebar is a natural follow-up; this keyboard path is the simplest
    /// thing that actually lets you reorder tabs today.
    func moveActiveTab(by offset: Int) {
        guard let tab = activeTab else { return }
        moveTab(tab, by: offset)
    }

    /// Moves `tab` by `offset` rows (clamped), in both the model and the sidebar.
    func moveTab(_ tab: Tab, by offset: Int) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }),
              let newIndex = TabSelection.destinationIndex(of: idx, offset: offset, spaces: tabs.map(\.spaceIndex)) else { return }

        // Every row springs from where it is on screen (a dragged row: under the pointer) to its new slot.
        let container = tab.tabButton.superview as? NSStackView
        let before = TabMotion.visualFrames(of: container?.arrangedSubviews ?? [])
        tabs.remove(at: idx)
        tabs.insert(tab, at: newIndex)
        journalTabMoved(tab, steps: offset)
        rebuildTabList()
        tabBarStack.superview?.layoutSubtreeIfNeeded()
        tabStrip.layoutSubtreeIfNeeded()
        TabMotion.reflow(container?.arrangedSubviews ?? [], from: before)
        saveSession()
    }

    // MARK: - Spaces

    func visibleTabs() -> [Tab] { tabs.filter { $0.spaceIndex == currentSpace } }

    /// Header of the tab column: "N onglets" (never mentions sleeping tabs: hibernation is invisible).
    func updateTabCount() {
        refreshNowPlaying()
        let mine = visibleTabs()
        let count = mine.count
        spaceMetaLabel.stringValue = "\(count) onglet\(count > 1 ? "s" : "")" + (profileName.map { " · \($0)" } ?? "")
        sleepMetaLabel.stringValue = ""
        spaceRail.setTabs(mine.map { tab in
            (tab.displayTitle, tab.badgeHost, tab.id == activeTabID, tab.isSuspended,
             { [weak self, weak tab] in if let tab { self?.selectTab(tab) } })
        })
    }

    /// Brings the sidebar in line with `currentSpace`: rail, header, lisière, which tab rows are shown.
    func refreshSpaceUI(animated: Bool) {
        let style = currentSpaceStyle
        spaceRail.configure(spaces: spaces, selected: currentSpace, compact: effectiveSidebarMode == .compact)
        if effectiveSidebarMode == .floating { refreshHoverSpaceRow() }          // keep the icon row's selection in sync
        spaceNameLabel.stringValue = style.name
        loadingBar.color = Theme.hue(style.hue)
        rebuildTabList()
        if animated { visibleTabs().forEach { $0.tabButton.animateIn() } }
        refreshPinnedIcons()
        if activePanel == .favorites { refreshPanel() }
    }

    // MARK: - Tab list and groups

    /// Lays out the tab column for the current space: groups (collapsible), then "Pages libres".
    func rebuildTabList() {
        let horizontal = SettingsStore.shared.tabLayout == .horizontal
        let items = tabs.map { TabListLayout.Item(id: $0.id, spaceIndex: $0.spaceIndex, groupID: $0.groupID) }
        let rows = TabListLayout.rows(tabs: items, groups: groups, space: currentSpace)
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let container: NSStackView = horizontal ? tabStrip.tabsStack : tabBarStack
        var desired: [NSView] = []
        for row in rows {
            switch row {
            case .groupHeader(let id):
                guard let group = groups.first(where: { $0.id == id }) else { continue }
                if horizontal {
                    desired.append(makeStripGroupChip(group.name, hue: currentSpaceStyle.hue))
                    continue
                }
                let members = tabs.filter { $0.groupID == id }.count
                let header = GroupHeaderView(name: group.name, tabCount: members, collapsed: group.collapsed)
                header.onToggle = { [weak self] in self?.toggleGroup(id) }
                header.contextMenuProvider = { [weak self] in self?.makeGroupMenu(for: id) }
                desired.append(header)
            case .looseHeader:
                if !horizontal { desired.append(makeSectionLabel("Pages libres")) }
            case .tab(let id, let indented):
                guard let tab = byID[id] else { continue }
                tab.tabButton.isHidden = false
                tab.tabButton.setHorizontal(horizontal)
                tab.tabButton.setIndented(indented && !horizontal)
                desired.append(tab.tabButton)
            }
        }
        if !horizontal { desired.append(inlineNewTabRow ?? makeInlineNewTabRow()) }   // right after the last tab, where the eye is when the list is long
        // The same rows in the same order (a title changed, a tab was selected): nothing to take apart. This pass cost 0,8 ms per tab.
        let tail: [NSView] = horizontal ? [tabStrip.overflowButton, tabStrip.newTabButton] : []
        let current = container.arrangedSubviews
        let other = horizontal ? tabBarStack : tabStrip.tabsStack
        let unchanged = other.arrangedSubviews.isEmpty && current.count == desired.count + tail.count
            && zip(current, desired + tail).allSatisfy { $0 === $1 }
        if !unchanged {
            for stack in [tabBarStack, tabStrip.tabsStack] {
                stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
            }
            desired.forEach(container.addArrangedSubview)
        }
        if horizontal {
            tabStrip.spaceChip.configure(currentSpaceStyle)
            tabStrip.activeTabView = activeTab?.tabButton
            tabStrip.tabsChanged()
        }
        updateTabCount()
        refreshWidgets()
    }

    /// The ▾ button of a full tab strip: every tab of this space, the one in front ticked; a pick brings it to the front.
    func showAllTabsMenu() {
        let menu = NSMenu()
        for tab in tabs where tab.spaceIndex == currentSpace {
            let item = ClosureMenuItem(title: tab.displayTitle.isEmpty ? (tab.badgeHost.isEmpty ? "Nouvel onglet" : tab.badgeHost) : tab.displayTitle) { [weak self, weak tab] in if let tab { self?.selectTab(tab) } }
            item.state = tab.id == activeTabID ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: tabStrip.overflowButton.bounds.height + 4), in: tabStrip.overflowButton)
    }

    func makeInlineNewTabRow() -> SidebarRowView {
        let row = SidebarRowView(symbol: "plus", title: "Nouvel onglet", shortcut: nil)
        row.onClick = { [weak self] in self?.newTabAction() }
        row.setAccessibilityLabel("Nouvel onglet")
        inlineNewTabRow = row
        return row
    }

    func toggleGroup(_ id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].collapsed.toggle()
        Motion.animate(Motion.standard) { rebuildTabList(); tabBarStack.superview?.layoutSubtreeIfNeeded() }
        saveSession()
    }

    func makeGroupMenu(for id: UUID) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Renommer le groupe…") { [weak self] in self?.renameGroup(id) })
        menu.addItem(ClosureMenuItem(title: "Dissoudre le groupe") { [weak self] in self?.dissolveGroup(id) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Fermer les onglets du groupe") { [weak self] in
            guard let self else { return }
            for tab in self.tabs where tab.groupID == id { self.closeTab(tab) }
            self.dissolveGroup(id)
        })
        return menu
    }

    func promptForText(title: String, button: String, initial: String, completion: @escaping @MainActor (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Annuler")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            mainActorNow { completion(String(text.prefix(30))) }
        }
    }

    func renameGroup(_ id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        promptForText(title: "Renommer le groupe", button: "Renommer", initial: groups[index].name) { [weak self] name in
            guard let self, let i = self.groups.firstIndex(where: { $0.id == id }) else { return }
            self.groups[i].name = name
            self.rebuildTabList()
            self.saveSession()
        }
    }

    func dissolveGroup(_ id: UUID) {
        for tab in tabs where tab.groupID == id { tab.groupID = nil }
        groups.removeAll { $0.id == id }
        rebuildTabList()
        saveSession()
    }

    /// Creates a group in the tab's space (asking for a name) and puts the tab in it.
    func newGroup(with tab: Tab) {
        promptForText(title: "Nouveau groupe", button: "Créer", initial: "") { [weak self, weak tab] name in
            guard let self, let tab else { return }
            let group = TabGroup(name: name, spaceIndex: tab.spaceIndex)
            self.groups.append(group)
            tab.groupID = group.id
            self.rebuildTabList()
            self.saveSession()
        }
    }

    func assign(_ tab: Tab, to groupID: UUID?) {
        tab.groupID = groupID
        if let groupID, let i = groups.firstIndex(where: { $0.id == groupID }), groups[i].collapsed { groups[i].collapsed = false }
        rebuildTabList()
        saveSession()
    }

    func setCurrentSpace(_ index: Int, animated: Bool) {
        guard index != currentSpace, spaces.indices.contains(index) else { return }
        let forward = index > currentSpace
        currentSpace = index
        UserDefaults.standard.set(index, forKey: Self.activeSpaceKey)
        refreshSpaceUI(animated: animated)
        if animated {
            // The new space's tabs drift in from the side the space sits on; names and colours cross-fade.
            let horizontal = SettingsStore.shared.tabLayout == .horizontal
            Motion.enter(horizontal ? tabStrip.tabsStack : tabBarStack, fromX: horizontal ? (forward ? 24 : -24) : 0,
                         fromY: horizontal ? 0 : (forward ? -14 : 14))
            [spaceNameLabel, spaceMetaLabel, tabStrip.spaceChip].forEach { Motion.crossfade($0) }
        }
    }

    /// User picked a space: show its tabs and go to the one you were last on there.
    func selectSpace(_ index: Int) {
        guard index != currentSpace, spaces.indices.contains(index) else { return }
        journal.emit("space.switch", ["from": .int(currentSpace), "to": .int(index)])
        journalSelectVia = "space"
        setCurrentSpace(index, animated: true)
        let remembered = lastActiveTabInSpace[index].flatMap { id in tabs.first { $0.id == id && $0.spaceIndex == index } }
        if let target = remembered ?? visibleTabs().first {
            selectTab(target)
        } else {
            newTab(urlString: nil, isPrivate: SettingsStore.shared.privateByDefault)   // empty space: start page
        }
        saveSession()
    }

    @objc func selectNextSpace() { selectSpace((currentSpace + 1) % spaces.count) }

    /// ⌃1…⌃3
    @objc func selectSpaceByNumber(_ sender: NSMenuItem) { selectSpace(sender.tag - 1) }

    func moveTab(_ tab: Tab, toSpace index: Int) {
        guard index != tab.spaceIndex, spaces.indices.contains(index) else { return }
        if splitContains(tab.id) { endSplit(keeping: nil) }
        let wasActive = tab.id == activeTabID
        tab.spaceIndex = index
        tab.groupID = nil
        refreshSpaceUI(animated: true)
        if wasActive {
            if let other = visibleTabs().first(where: { $0.id != tab.id }) {
                selectTab(other)
            } else {
                newTab(urlString: nil, isPrivate: SettingsStore.shared.privateByDefault)
            }
        }
        saveSession()
    }

    /// Adds a space with the next unused hue (the full editor — name, icon, hue — comes with the overview screen).
    func addSpace(select: Bool = true) {
        let used = Set(spaces.map(\.hue))
        let hue = OreeTokens.Hue.allCases.first { !used.contains($0) } ?? .graphite
        let icons = SpaceIcon.allCases
        spaces.append(SpaceStyle(name: "Espace \(spaces.count + 1)", hue: hue, icon: icons[spaces.count % icons.count]))
        if select { selectSpace(spaces.count - 1) }
        refreshSpaceUI(animated: false)
    }

    func renameSpace(_ index: Int) {
        guard let window, spaces.indices.contains(index) else { return }
        let alert = NSAlert()
        alert.messageText = "Renommer l'espace"
        alert.addButton(withTitle: "Renommer")
        alert.addButton(withTitle: "Annuler")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = spaces[index].name
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            mainActorNow {
                self.spaces[index].name = String(name.prefix(14))
                self.refreshSpaceUI(animated: false)
            }
        }
    }

    // MARK: - Tab menu, reopen, shortcuts

    func makeTabMenu(for tab: Tab) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, enabled: Bool = true, _ action: @escaping @MainActor () -> Void) {
            let item = ClosureMenuItem(title: title, action: action)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add("Recharger", enabled: tab.webView != nil) { tab.webView?.reload() }
        add("Dupliquer") { [weak self] in
            if let url = tab.currentURL { self?.newTab(urlString: url.absoluteString, isPrivate: tab.isPrivate) }
        }
        let isFavorite = tab.currentURL.flatMap { try? bookmarkRepo.contains(url: $0.absoluteString) } ?? false
        add(isFavorite ? "Retirer des favoris" : "Ajouter aux favoris", enabled: tab.currentURL != nil) { [weak self] in
            self?.toggleBookmark(for: tab)
        }
        add("Ajouter à la liste de lecture", enabled: tab.currentURL != nil) { [weak self] in self?.addToReadingList(tab) }
        add("Copier le lien", enabled: tab.currentURL != nil) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.currentURL?.absoluteString ?? "", forType: .string)
        }
        let groupItem = NSMenuItem(title: "Ajouter au groupe", action: nil, keyEquivalent: "")
        let groupMenu = NSMenu()
        for group in groups where group.spaceIndex == tab.spaceIndex && group.id != tab.groupID {
            groupMenu.addItem(ClosureMenuItem(title: group.name) { [weak self] in self?.assign(tab, to: group.id) })
        }
        if !groupMenu.items.isEmpty { groupMenu.addItem(.separator()) }
        groupMenu.addItem(ClosureMenuItem(title: "Nouveau groupe…") { [weak self] in self?.newGroup(with: tab) })
        groupItem.submenu = groupMenu
        menu.addItem(groupItem)
        if tab.groupID != nil { add("Retirer du groupe") { [weak self] in self?.assign(tab, to: nil) } }
        add("Ouvrir côte à côte", enabled: tab.id != activeTabID && activeTab != nil && !(activeTab?.isPrivate ?? true) == !tab.isPrivate) { [weak self] in
            guard let self, let active = self.activeTab else { return }
            self.beginSplit(left: active, right: tab)
        }
        let host = tab.currentURL?.host?.lowercased().replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
        if let host, !host.isEmpty {
            let never = SettingsStore.shared.neverSleepHosts.contains(host)
            add(never ? "Autoriser la mise en veille de \(host)" : "Ne jamais mettre en veille \(host)") {
                var hosts = SettingsStore.shared.neverSleepHosts
                if never { hosts.removeAll { $0 == host } } else { hosts.append(host) }
                SettingsStore.shared.neverSleepHosts = hosts
                if !never { tab.thaw() }
            }
        }
        if let host = ProtectionPolicy.normalized(tab.currentURL?.host), tab.currentURL?.scheme?.hasPrefix("http") == true {
            let off = ProtectionPolicy.isExempt(host: host, list: SettingsStore.shared.protectionExemptHosts)
            add(off ? "Réactiver les protections sur \(host)" : "Désactiver les protections sur \(host)") { [weak self] in
                var list = SettingsStore.shared.protectionExemptHosts
                if off { list.removeAll { host == $0 || host.hasSuffix("." + $0) } } else { list.append(host) }
                SettingsStore.shared.protectionExemptHosts = list
                tab.webView?.reload()
                _ = self
            }
        }
        add("Mettre en veille", enabled: !tab.isSuspended && tab.webView != nil && (tab.id != activeTabID || visibleTabs().count > 1)) { [weak self] in
            self?.sleepTab(tab)
        }
        let moveItem = NSMenuItem(title: "Déplacer vers…", action: nil, keyEquivalent: "")
        let moveMenu = NSMenu()
        for (index, name) in spaces.map(\.name).enumerated() where index != tab.spaceIndex {
            moveMenu.addItem(ClosureMenuItem(title: name) { [weak self] in self?.moveTab(tab, toSpace: index) })
        }
        moveItem.submenu = moveMenu
        menu.addItem(moveItem)
        menu.addItem(.separator())
        let following = tabs.filter { $0.spaceIndex == tab.spaceIndex }.drop(while: { $0.id != tab.id }).dropFirst()
        add(SettingsStore.shared.tabLayout == .horizontal ? "Fermer les onglets à droite" : "Fermer les onglets en dessous", enabled: !following.isEmpty) { [weak self] in
            for other in following { self?.closeTab(other) }
        }
        add("Ouvrir dans une mini-fenêtre", enabled: tab.currentURL != nil) { [weak self, weak tab] in if let url = tab?.currentURL { self?.openMiniWindow(url: url) } }
        add("Déplacer vers une nouvelle fenêtre", enabled: tabs.count > 1) { [weak self, weak tab] in if let tab { self?.detachToNewWindow(tab) } }
        add("Fermer les autres onglets", enabled: tabs.filter({ $0.spaceIndex == tab.spaceIndex }).count > 1) { [weak self] in
            guard let self else { return }
            for other in self.tabs where other.id != tab.id && other.spaceIndex == tab.spaceIndex { self.closeTab(other) }
        }
        add("Fermer l'onglet") { [weak self] in self?.closeTab(tab) }
        return menu
    }

    // MARK: - Tab suspension (memory optimization)

    func startSuspensionTimer() {
        suspensionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.suspendInactiveTabs() }
        }
    }

    /// Steady-state hygiene, once a minute: same pass as the memory timer (freeze / sleep by idle time).
    func suspendInactiveTabs() async {
        await enforceMemoryBudget()
        archiveStaleTabs()
    }
}
