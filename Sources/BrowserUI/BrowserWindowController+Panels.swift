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

    // MARK: - Side panels

    func togglePanel(_ kind: PanelKind?) {
        let before = activePanel
        activePanel = (kind == activePanel) ? nil : kind
        if let now = activePanel { journalPanel(String(describing: now), open: true) } else if let old = before { journalPanel(String(describing: old), open: false) }
        refreshPanel()
    }

    /// Shows the chosen panel in place of the tab list (or brings the tabs back).
    func refreshPanel() {
        for (kind, button) in panelButtons { button.isActive = kind == activePanel }
        guard let kind = activePanel else {
            sidePanel.isHidden = true
            panelScroll?.isHidden = false
            return
        }
        panelScroll?.isHidden = true
        let open: (String) -> Void = { [weak self] url in self?.newTab(urlString: url, isPrivate: false) }
        switch kind {
        case .favorites:
            let items = ((try? bookmarkRepo.all(forSpace: currentSpace)) ?? []).map { b in
                PanelEntry(icon: .site(HomeFormatting.displayHost(b.url)), title: b.title.isEmpty ? HomeFormatting.displayHost(b.url) : b.title,
                           subtitle: HomeFormatting.displayHost(b.url), open: { open(b.url) },
                           remove: { [weak self] in try? self?.bookmarkRepo.remove(url: b.url); self?.menuBuilder?.refreshBookmarksMenu(); self?.refreshPinnedIcons(); self?.refreshPanel() })
            }
            sidePanel.show(title: "Favoris", sections: [PanelSection(title: nil, entries: items)], emptyText: "Aucun favori dans cet espace.")
        case .history:
            let entries = (try? historyRepo.recent(limit: 80)) ?? []
            let cal = Calendar.current
            func group(_ d: Date) -> String { cal.isDateInToday(d) ? "Aujourd’hui" : cal.isDateInYesterday(d) ? "Hier" : "Plus ancien" }
            var sections: [PanelSection] = []
            for name in ["Aujourd’hui", "Hier", "Plus ancien"] {
                let items = entries.filter { group($0.lastVisitedAt) == name && URL(string: $0.url)?.scheme != "oree" }.map { e in
                    PanelEntry(icon: .site(HomeFormatting.displayHost(e.url)), title: e.title.isEmpty ? HomeFormatting.displayHost(e.url) : e.title,
                               subtitle: "\(HomeFormatting.displayHost(e.url)) · \(HomeFormatting.relative(e.lastVisitedAt))", open: { open(e.url) }, remove: nil)
                }
                sections.append(PanelSection(title: name, entries: items))
            }
            sidePanel.show(title: "Historique", sections: sections, emptyText: "Rien dans l’historique pour l’instant.")
        case .downloads:
            let items = downloads.items.map { item in
                PanelEntry(icon: .symbol("doc"), title: item.name,
                           subtitle: item.phase == .running ? ByteFormat.progressLine(item.snapshot) : (item.phase == .finished ? "Terminé" : item.phase == .paused ? "En pause" : (item.error ?? "Échec")),
                           open: { [weak self] in if item.phase == .finished { self?.downloads.reveal(item.id) } }, remove: nil)
            }
            sidePanel.show(title: "Téléchargements", sections: [PanelSection(title: nil, entries: items)], emptyText: "Aucun téléchargement pour l’instant.")
        case .reading:
            let items = ((try? readingRepo.all()) ?? []).map { r in
                PanelEntry(icon: .site(HomeFormatting.displayHost(r.url)), title: r.title.isEmpty ? HomeFormatting.displayHost(r.url) : r.title,
                           subtitle: HomeFormatting.displayHost(r.url), open: { open(r.url) },
                           remove: { [weak self] in try? self?.readingRepo.remove(url: r.url); self?.refreshPanel() })
            }
            sidePanel.show(title: "Liste de lecture", sections: [PanelSection(title: nil, entries: items)],
                           emptyText: "Ajoutez des pages avec clic droit sur un onglet → « Ajouter à la liste de lecture ».")
        }
    }

    /// Clic droit / palette: keeps a page for later.
    func addToReadingList(_ tab: Tab) {
        guard let url = tab.currentURL, url.scheme == "http" || url.scheme == "https" else { return }
        try? readingRepo.add(url: url.absoluteString, title: tab.displayTitle)
        if activePanel == .reading { refreshPanel() }
    }

    @objc func openHistoryPanel() { activePanel = .history; journalPanel("history", open: true); refreshPanel() }

    // MARK: - Downloads

    func downloadsChanged() {
        if activePanel == .downloads { refreshPanel() }
        let summary = downloads.summary
        setRelevant(.downloads, downloads.hasItems)
        downloadsButton.ringIndeterminate = summary.running > 0 && summary.fraction == nil
        downloadsButton.ringProgress = summary.running > 0 && summary.fraction != nil ? summary.fraction : nil
        let tip = summary.running > 0 ? "Téléchargements — \(summary.running) en cours · \(ByteFormat.speed(summary.bytesPerSecond))" : "Téléchargements"
        downloadsButton.toolTip = tip
        downloadsButton.setAccessibilityLabel(tip + (summary.fraction.map { ", \(Int($0 * 100)) %" } ?? ""))
        downloadsPanel?.refresh()
        if let popover = downloadsPopover, popover.isShown, let panel = downloadsPanel { popover.contentSize = panel.frame.size }
    }

    func toggleDownloads() {
        journalPanel("downloads", open: !(downloadsPopover?.isShown ?? false))
        if let popover = downloadsPopover, popover.isShown { popover.close(); return }
        let popover = NSPopover()
        popover.behavior = .transient
        let panel = DownloadsPanelView(controller: downloads)
        let controller = NSViewController()
        controller.view = panel
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: DownloadsPanelView.width, height: panel.frame.height)
        guard showPopoverSafely(popover, relativeTo: downloadsButton, fallback: addressPill) else { return }
        downloadsPopover = popover
        downloadsPanel = panel
    }

    // MARK: - Split screen

    func splitContains(_ id: UUID) -> Bool { splitPair.map { $0.left == id || $0.right == id } ?? false }

    /// A tab shown in the split screen but not focused is still on screen: never put it to sleep.
    func isOnScreen(_ tab: Tab) -> Bool { tab.id == activeTabID || splitContains(tab.id) }

    func ensureAwake(_ tab: Tab) {
        if tab.isFrozen { tab.thaw() }   // instant: the page was only paused
        guard tab.isSuspended else { return }
        let webView = tab.wake()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// ⌘\ — split with the most recently used other tab of the space (or a fresh tab); again to leave.
    @objc func toggleSplit() {
        if splitPair != nil { endSplit(keeping: activeTabID); return }
        guard let active = activeTab else { return }
        let candidate = visibleTabs()
            .filter { $0.id != active.id && $0.isPrivate == active.isPrivate }
            .max { $0.lastActiveDate < $1.lastActiveDate }
        let partner = candidate ?? newTab(urlString: nil, isPrivate: active.isPrivate)
        beginSplit(left: active, right: partner)
    }

    func beginSplit(left: Tab, right: Tab) {
        guard left.id != right.id, left.spaceIndex == right.spaceIndex else { return }
        if splitPair != nil { endSplit(keeping: left.id) }
        for tab in [left, right] { ensureAwake(tab); tab.contentSlot.isHidden = false }
        splitPair = (left.id, right.id)
        splitRatio = 0.5
        splitButton.isActive = true
        installSplitLayout()
        saveSession()
        splitMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            mainActorNow { self?.focusPane(at: event) }
            return event
        }
        selectTab(left)
    }

    /// Re-pins the two slots side by side, with a header over each and the hinge between them.
    func installSplitLayout() {
        guard let pair = splitPair,
              let left = tabs.first(where: { $0.id == pair.left }), let right = tabs.first(where: { $0.id == pair.right }) else { return }
        NSLayoutConstraint.deactivate(splitConstraints); splitConstraints = []
        splitHeaders.values.forEach { $0.removeFromSuperview() }; splitHeaders = [:]
        splitHinge?.removeFromSuperview()

        let headerHeight: CGFloat = 34, hingeWidth: CGFloat = 40
        left.slotTrailing?.isActive = false
        right.slotLeading?.isActive = false
        left.slotTop?.constant = headerHeight
        right.slotTop?.constant = headerHeight

        let leftWidth = left.contentSlot.widthAnchor.constraint(equalTo: contentContainer.widthAnchor, multiplier: splitRatio, constant: -6)
        splitLeftWidth = leftWidth
        let rightLeading = right.contentSlot.leadingAnchor.constraint(equalTo: left.contentSlot.trailingAnchor, constant: 12)
        splitConstraints += [leftWidth, rightLeading]

        let hinge = SplitHingeView()
        hinge.ratio = splitRatio
        hinge.onRatio = { [weak self] ratio, final in self?.setSplitRatio(ratio, animated: final) }
        hinge.onSwap = { [weak self] in self?.swapSplit() }
        splitHinge = hinge
        contentContainer.addSubview(hinge)
        splitConstraints += [
            hinge.widthAnchor.constraint(equalToConstant: hingeWidth),
            hinge.centerXAnchor.constraint(equalTo: left.contentSlot.trailingAnchor, constant: 6),
            hinge.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: headerHeight),
            hinge.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ]

        for (tab, side) in [(left, 0), (right, 1)] {
            let header = SplitPaneHeader()
            header.onFocus = { [weak self, weak tab] in if let tab { self?.selectTab(tab) } }
            header.onSolo = { [weak self, weak tab] in if let tab { self?.endSplit(keeping: tab.id) } }
            header.onClose = { [weak self, weak tab] in
                guard let self, let tab, let pair = self.splitPair else { return }
                self.endSplit(keeping: tab.id == pair.left ? pair.right : pair.left)
            }
            contentContainer.addSubview(header, positioned: .below, relativeTo: loadingBar)
            splitHeaders[tab.id] = header
            splitConstraints += [
                header.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                header.leadingAnchor.constraint(equalTo: tab.contentSlot.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: tab.contentSlot.trailingAnchor),
            ]
            _ = side
        }
        NSLayoutConstraint.activate(splitConstraints)
        refreshSplitHeaders()
        contentContainer.layoutSubtreeIfNeeded()
    }

    func refreshSplitHeaders() {
        guard splitPair != nil else { return }
        for (id, header) in splitHeaders {
            guard let tab = tabs.first(where: { $0.id == id }) else { continue }
            header.configure(title: tab.displayTitle, host: tab.badgeHost)
            header.isFocused = id == activeTabID
        }
        splitHinge?.ratio = splitRatio
    }

    func setSplitRatio(_ ratio: CGFloat, animated: Bool) {
        splitRatio = ratio
        guard let old = splitLeftWidth, let pair = splitPair, let left = tabs.first(where: { $0.id == pair.left }) else { return }
        let new = left.contentSlot.widthAnchor.constraint(equalTo: contentContainer.widthAnchor, multiplier: ratio, constant: -6)
        NSLayoutConstraint.deactivate([old]); splitConstraints.removeAll { $0 === old }
        new.isActive = true; splitConstraints.append(new); splitLeftWidth = new
        if animated {
            Motion.animate(Motion.standard) { contentContainer.animator().layoutSubtreeIfNeeded() }
        } else {
            contentContainer.layoutSubtreeIfNeeded()
        }
        splitHinge?.ratio = ratio
        if animated { saveSession() }
    }

    func swapSplit() {
        guard let pair = splitPair else { return }
        splitPair = (pair.right, pair.left)
        installSplitLayout()
        saveSession()
    }

    /// Back to a single page. `keeping` is the tab that stays visible (nil = the focused one).
    func endSplit(keeping id: UUID?) {
        guard let pair = splitPair else { return }
        if let splitMonitor { NSEvent.removeMonitor(splitMonitor) }
        splitMonitor = nil
        NSLayoutConstraint.deactivate(splitConstraints); splitConstraints = []
        splitHeaders.values.forEach { $0.removeFromSuperview() }; splitHeaders = [:]
        splitHinge?.removeFromSuperview(); splitHinge = nil
        splitLeftWidth = nil
        splitPair = nil
        splitButton.isActive = false
        let keep = id ?? activeTabID
        for tab in tabs where tab.id == pair.left || tab.id == pair.right {
            tab.slotTop?.constant = 0
            tab.slotLeading?.isActive = true
            tab.slotTrailing?.isActive = true
            tab.contentSlot.isHidden = tab.id != keep
        }
        contentContainer.layoutSubtreeIfNeeded()
        if let keep, let tab = tabs.first(where: { $0.id == keep }), activeTabID != keep { selectTab(tab) }
        saveSession()
    }

    /// A click inside one of the two sides focuses it (web views swallow the click, so we peek at it).
    func focusPane(at event: NSEvent) {
        guard let pair = splitPair, event.window === window else { return }
        let point = contentContainer.convert(event.locationInWindow, from: nil)
        guard contentContainer.bounds.contains(point) else { return }
        for id in [pair.left, pair.right] {
            guard let tab = tabs.first(where: { $0.id == id }), id != activeTabID else { continue }
            if tab.contentSlot.frame.contains(point) { selectTab(tab); return }
        }
    }

    /// Shows the welcome once (never in scripted runs, which always start fresh).
    public func showOnboardingIfNeeded() {
        guard !SettingsStore.shared.onboardingDone, !isFreshSession else { return }
        onboarding.present()
    }

    /// Daily, silent unless a newer version exists.
    public static func purgeSnapshots() { Tab.purgeSnapshots(); GhostStorage.purge() }

    /// At quit: keeps (encrypted) what each open, non-private tab looks like, so that on the next launch a tab that wakes does not show a
    /// blank page while it loads. Whatever belongs to a tab that is no longer open is deleted.
    public func persistSleepSnapshots() {
        guard !isFreshSession else { return }
        var kept = Set<String>()
        for tab in tabs where SessionPolicy.isSavable(url: tab.currentURL, isPrivate: tab.isPrivate) {
            guard let address = tab.currentURL?.absoluteString else { continue }
            kept.insert(address)
            if let picture = tab.pictureForNextLaunch { try? SnapshotVault.shared.put(picture, for: address) }
        }
        SnapshotVault.shared.prune(keeping: kept)
    }

    public func checkForUpdatesInBackground() { AppUpdater.shared.checkInBackgroundIfDue() }

    @objc func checkForUpdates() { AppUpdater.shared.checkNow() }

    @objc func showAbout() { AboutPanel.shared.present() }

    /// Automation only.
    @objc func automationOnboarding() { onboarding.present() }

    // MARK: - Spaces overview

    /// ⌃↑
    @objc func openOverview() {
        journalPanel("overview", open: true)
        palette.isHidden = true
        overview.present()
    }

    func closeOverview() {
        overview.dismiss()
        if let webView = activeTab?.webView { window?.makeFirstResponder(webView) }
    }

    func overviewCards() -> [SpaceCardData] {
        spaces.enumerated().map { index, style in
            let mine = tabs.filter { $0.spaceIndex == index }
            let groupNames = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.name) })
            // Grouped tabs first (in group order), then loose ones — collapsed groups still list their tabs.
            let grouped = groups.filter { $0.spaceIndex == index }.flatMap { group in mine.filter { $0.groupID == group.id } }
            let groupedIDs = Set(grouped.map(\.id))
            let ordered = grouped + mine.filter { !groupedIDs.contains($0.id) }
            let entries = ordered.map { tab in
                SpaceCardData.Entry(title: tab.displayTitle, host: tab.badgeHost, sleeping: tab.isSuspended,
                                    group: tab.groupID.flatMap { groupedIDs.contains(tab.id) ? groupNames[$0] : nil })
            }
            return SpaceCardData(index: index, style: style, entries: entries, isCurrent: index == currentSpace)
        }
    }

    /// Removes a space; its tabs move to the neighbouring one (nothing the user opened is lost).
    func deleteSpace(_ index: Int) {
        guard spaces.count > 1, spaces.indices.contains(index) else { return }
        for tab in tabs { tab.spaceIndex = SpaceReindex.newIndex(tab.spaceIndex, afterDeleting: index) }
        let removedGroups = Set(groups.filter { $0.spaceIndex == index }.map(\.id))
        for tab in tabs where tab.groupID.map(removedGroups.contains) == true { tab.groupID = nil }
        groups.removeAll { removedGroups.contains($0.id) }
        for i in groups.indices { groups[i].spaceIndex = SpaceReindex.newIndex(groups[i].spaceIndex, afterDeleting: index) }
        closedTabs = closedTabs.map { ($0.url, $0.state, $0.title, SpaceReindex.newIndex($0.space, afterDeleting: index)) }
        var remembered: [Int: UUID] = [:]
        for (space, id) in lastActiveTabInSpace where space != index { remembered[SpaceReindex.newIndex(space, afterDeleting: index)] = id }
        lastActiveTabInSpace = remembered
        try? bookmarkRepo.reindex(afterDeletingSpace: index)
        spaces.remove(at: index)
        currentSpace = SpaceReindex.newIndex(currentSpace, afterDeleting: index)
        UserDefaults.standard.set(currentSpace, forKey: Self.activeSpaceKey)
        refreshSpaceUI(animated: false)
        saveSession()
    }

    // MARK: - Customization drawer

    /// ⌘,
    @objc func openCustomize() {
        journalPanel("customize", open: true)
        palette.isHidden = true
        drawer.present()
        window?.makeFirstResponder(drawer)
    }

    func closeCustomize() {
        drawer.dismiss()
        if let webView = activeTab?.webView { window?.makeFirstResponder(webView) }
    }

    func pickHomePhoto() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .webP]
        panel.allowsMultipleSelection = false
        panel.message = "Choisissez la photo de la page d’accueil"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            mainActorNow {
                SettingsStore.shared.homePhotoPath = url.path
                SettingsStore.shared.homeBackground = .photo
                self?.drawer.refreshFromSettings()
                self?.applyLookChanges()
            }
        }
    }

    /// Pushes the look settings (theme, accent, density, radius, text size, sidebar, home) into the live window.
    func applyLookChanges() {
        let store = SettingsStore.shared
        lastLook = LookProfile.capture(named: "", from: store)
        lastSidebarPrefs = [store.sidebarWidth, store.sidebarGlass ? 1 : 0]
        Theme.applyAppearance(store.appearanceMode)
        Theme.accentHue = store.accentHue
        Theme.density = store.density
        Theme.radiusBase = store.cornerRadius
        Theme.textOffset = CGFloat(store.uiTextOffset)

        for tab in tabs { tab.tabButton.refreshMetrics() }
        searchRow?.refreshMetrics()
        newTabRow?.refreshMetrics()
        addressPill.refreshMetrics()
        spaceNameLabel.font = Theme.Typo.subheading
        spaceMetaLabel.font = Theme.sans(12)
        applySidebarMode(animated: true)
        refreshSpaceUI(animated: false)
        for tab in tabs { tab.contentSlot.needsDisplay = true }
        reloadHomePages()
        NotificationCenter.default.post(name: Theme.didChange, object: nil)
    }

    /// Re-renders open home pages so they pick up background, toggles, accent and radius.
    func reloadHomePages() {
        for tab in tabs where tab.webView?.url?.scheme == "oree" && tab.webView?.url?.host == "home" {
            tab.webView?.loadHTMLString(StartPage.render(homeInput(for: tab)), baseURL: StartPage.baseURL)
        }
    }

    // MARK: - Disposition des boutons (barre d'outils, barre latérale)

    func chromeButton(_ item: ChromeItem) -> ChromeIconButton? {
        switch item {
        case .sidebarToggle: toggleSidebarButton
        case .back: backButton
        case .forward: forwardButton
        case .reload: reloadButton
        case .assistant: assistantButton
        case .calendar: calendarButton
        case .essentiel: digestButton
        case .night: nightButton
        case .translate: translateButton
        case .split: splitButton
        case .customize: customizeButton
        case .downloads: downloadsButton
        case .more: moreButton
        case .favorites: panelButtons.first { $0.kind == .favorites }?.button
        case .history: panelButtons.first { $0.kind == .history }?.button
        case .downloadsPanel: panelButtons.first { $0.kind == .downloads }?.button
        case .reading: panelButtons.first { $0.kind == .reading }?.button
        }
    }

    /// Un bouton « selon la page » sert (ou ne sert plus) : on ne retouche la disposition que si cela change quelque chose.
    func setRelevant(_ item: ChromeItem, _ on: Bool) {
        guard chromeRelevant.contains(item) != on else { return }
        if on { chromeRelevant.insert(item) } else { chromeRelevant.remove(item) }
        applyChromeLayout()
    }

    /// Range chaque bouton là où la disposition le veut : barre d'outils à gauche / à droite, bas de la barre latérale, ou nulle part.
    /// Un bouton « selon la page » reste à sa place (grisé) s'il est épinglé, sinon il n'apparaît que quand il sert.
    func applyChromeLayout() {
        guard let toolbar else { return }
        let layout = SettingsStore.shared.chromeLayout
        appliedChromeLayout = layout
        let stacks: [(ChromeZone, NSStackView?, [NSView])] = [(.toolbarLeading, toolbar.leftStack, []), (.toolbarTrailing, toolbar.rightStack, []), (.sidebarFooter, footerStack, footerTail)]
        for (_, stack, _) in stacks { stack?.arrangedSubviews.forEach { stack?.removeArrangedSubview($0); $0.removeFromSuperview() } }
        let side = CGFloat(layout.iconSize.button), glyph = CGFloat(layout.iconSize.glyph)
        for item in ChromeItem.allCases { chromeButton(item)?.resize(side: side, glyph: glyph) }
        for (zone, stack, tail) in stacks {
            guard let stack else { continue }
            for item in layout.visibleItems(in: zone, relevant: { chromeRelevant.contains($0) }) {
                guard let button = chromeButton(item) else { continue }
                if isMini && zone != .sidebarFooter && ![.sidebarToggle, .back, .forward, .reload].contains(item) { continue }   // a small window keeps the essentials
                button.isHidden = false
                button.isEnabled = !item.isContextual || chromeRelevant.contains(item)
                stack.addArrangedSubview(button)
            }
            tail.forEach(stack.addArrangedSubview)
        }
        for item in ChromeItem.allCases { chromeButton(item)?.contextMenuProvider = { [weak self] in self?.chromeMenu(for: item) } }
        searchRow?.collapsed = !layout.showSearchRow
        newTabRow?.collapsed = !layout.showNewTabRow
    }

    /// Clic droit sur un bouton : le masquer, le déplacer, le garder à sa place — sans passer par les réglages.
    func chromeMenu(for item: ChromeItem) -> NSMenu {
        let menu = NSMenu()
        let layout = SettingsStore.shared.chromeLayout
        func update(_ change: @escaping (inout ChromeLayout) -> Void) {
            var edited = SettingsStore.shared.chromeLayout
            change(&edited)
            SettingsStore.shared.chromeLayout = edited
            applyChromeLayout()
        }
        let header = NSMenuItem(title: item.title, action: nil, keyEquivalent: ""); header.isEnabled = false
        menu.addItem(header)
        if item.isContextual {
            let pin = ClosureMenuItem(title: "Toujours à sa place (grisé quand il ne sert pas)") { update { if $0.pinned.contains(item) { $0.pinned.remove(item) } else { $0.pinned.insert(item) } } }
            pin.state = layout.pinned.contains(item) ? .on : .off
            menu.addItem(pin)
        }
        let move = NSMenuItem(title: "Déplacer vers", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for zone in ChromeZone.allCases where zone != .hidden && zone != layout.zone(of: item) {
            submenu.addItem(ClosureMenuItem(title: zone.title) { update { $0.move(item, to: zone) } })
        }
        move.submenu = submenu
        menu.addItem(move)
        if !item.isRequired { menu.addItem(ClosureMenuItem(title: "Masquer ce bouton") { update { $0.move(item, to: .hidden) } }) }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Personnaliser les barres…") { [weak self] in
            self?.openSettings()
            NotificationCenter.default.post(name: Notification.Name("Oree.selectSettingsCategory"), object: "layout")
        })
        return menu
    }

    /// L'IA ouvre une adresse dans l'onglet actif (la personne la voit) et attend la fin du chargement, au plus 15 s.
    func agentNavigate(_ urlString: String) async -> Bool {
        guard let tab = activeTab, let web = tab.webView else { return false }
        load(urlString: urlString, in: tab)
        try? await Task.sleep(for: .milliseconds(400))
        for _ in 0..<60 where web.isLoading && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(250)) }
        return !web.isLoading
    }

    func pushPage(by pushed: CGFloat) {
        guard let edge = pageTrailing else { return }
        // 8 pt de « chrome » entre la page et le panneau (où se trouve la poignée) ; la page arrondit son coin haut-droit à 14 quand elle est poussée.
        contentContainer.maskedCorners = pushed > 0 ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMaxYCorner]
        Motion.animate(Motion.slow) { edge.animator().constant = pushed > 0 ? -(pushed + 8) : 0 }
    }

    func aiBar() -> AIPanelController {
        if let aiBarController { return aiBarController }
        guard let contentView = window?.contentView else { fatalError("fenêtre sans contenu") }
        let hooks = AIPanelController.Hooks(
            activeWebView: { [weak self] in self?.activeTab?.webView },
            pageHost: { [weak self] in self?.contentContainer },
            navigate: { [weak self] urlString in await self?.agentNavigate(urlString) ?? false },
            openTab: { [weak self] url in _ = self?.newTab(urlString: url.absoluteString, isPrivate: false) },
            windowWidth: { [weak self] in self?.window?.contentView?.bounds.width ?? 1200 },
            isPrivate: { [weak self] in self?.activeTab?.isPrivate ?? false },
            onLayout: { [weak self] pushed in self?.pushPage(by: pushed) },
            recall: { [weak self] query in
                guard let self else { return [] }
                let words = PageMemoryPolicy.keywords(from: query)
                // La recherche exige tous les mots : on essaie tous les mots, puis en retirant le dernier, jusqu'à trouver.
                var tried = words
                while !tried.isEmpty {
                    if let hits = try? self.pageMemory.search(words: tried), !hits.isEmpty { return hits.map { (title: $0.title, host: $0.host, url: $0.url, snippet: $0.snippet, readAt: $0.readAt) } }
                    tried.removeLast()
                }
                return []
            },
            searchHistory: { [weak self] query in
                guard let self else { return [] }
                let history = ((try? self.historyRepo.search(matching: query, limit: 8)) ?? []).map { (title: $0.title, url: $0.url) }
                let needle = query.lowercased()
                let marks = ((try? self.bookmarkRepo.all()) ?? []).filter { $0.title.lowercased().contains(needle) || $0.url.lowercased().contains(needle) }.prefix(5).map { (title: $0.title, url: $0.url) }
                return Array(marks) + history
            },
            addNote: { [weak self] text in self?.openNotes(append: text) },
            openAnswerPage: { [weak self] title, html in
                guard let self else { return }
                let opened = self.newTab(urlString: nil, isPrivate: self.activeTab?.isPrivate ?? false)
                opened.webView?.loadHTMLString(html, baseURL: nil)
            },
            assistantFrame: { [weak self] in self.map { $0.assistantButton.convert($0.assistantButton.bounds, to: nil) } },
            keepPassage: { [weak self] passage in
                guard let self, let tab = self.activeTab, !tab.isPrivate, let page = tab.currentURL, ["http", "https"].contains(page.scheme?.lowercased() ?? "") else { return }
                let link = SelectionPassage.linkURL(page: page, passage: passage)
                let quote = SelectionPassage.excerpt(passage, limit: 60)
                try? self.readingRepo.add(url: link.absoluteString, title: "\(tab.displayTitle) — « \(quote) »")
                self.showToolNotice("Passage gardé dans votre liste de lecture.")
            })
        let created = AIPanelController(contentView: contentView, top: contentContainer.topAnchor, hooks: hooks)
        created.onRestPose = { [weak self] pose in
            guard let self, SettingsStore.shared.lucioleInPage else { return }
            if let pose { self.assistantMascot.apply(pose) }
            if pose == nil { self.assistantMascot.alphaValue = 0; return }                 // elle part : plus rien ne reste dans la barre d'outils, la copie qui vole prend le relais
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.reduced ? 0 : 0.25
                self.assistantMascot.animator().alphaValue = 1
            }
        }
        created.onVisibilityChange = { [weak self] open in self?.assistantButton.isActive = open; self?.journalPanel("ai", open: open) }
        created.onTaskFinished = { [weak self] route, ms, ok, usage in
            self?.journal.emit("ai.task", ["route": .string(route), "req": .int(usage.requests), "tin": .int(usage.promptTokens), "tout": .int(usage.completionTokens), "ms": .int(ms),
                                           "ok": .bool(ok), "retries": .int(usage.retries), "searches": .int(usage.searches)])
        }
        aiBarController = created
        created.tabChanged(id: activeTab?.id, title: activeTab?.displayTitle)
        return created
    }

    /// Clic droit sur une sélection › Expliquer / Traduire / Garder avec Luciole.
    func lucioleGesture(_ gesture: SelectionPassage.Gesture) { aiBar().gestureFromMenu(gesture) }

    /// Le script de lecture de Luciole a vu une sélection, sa disparition ou un défilement.
    func handleLucioleSelection(tab: Tab, json: String) {
        guard tab.id == activeTab?.id, SettingsStore.shared.lucioleInPage else { return }
        aiBar().selectionMessage(tab: tab, json: json)
    }

    /// ⌘J : le panneau IA (Luciole). Le modèle se réveille dès qu'il s'ouvre, pour être prêt quand la question est tapée.
    @objc func askAIAction() { aiBar().toggle() }

    // MARK: - Password manager

    /// Saved logins only ever apply to a secure origin (or a local dev server).
    func isEligibleForCredentials(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host else { return false }
        if url.scheme == "https" { return true }
        return url.scheme == "http" && (host == "localhost" || host == "127.0.0.1")
    }

    func handleCredentialMessage(webView: WKWebView, origin: String, body: [String: Any]) {
        guard (isEligibleForCredentials(origin) || (body["type"] as? String) == "cookieBanner"), let tab = tab(for: webView),
              let type = body["type"] as? String else { return }
        switch type {
        case "focus":
            Task { await offerAutofill(in: tab, webView: webView, origin: origin) }
        case "address", "card":
            Task { await offerAutofillMenu(kind: type, body: body, tab: tab, webView: webView) }
        case "addressSubmit", "cardSubmit":
            guard !tab.isPrivate, let values = body["values"] as? [String: String] else { return }
            Task { await (type == "cardSubmit" ? offerToSaveCard(values) : offerToSaveAddress(values)) }
        case "cookieBanner":
            SettingsStore.shared.cookieBannersRejected += 1
        case "otp":
            guard !tab.isPrivate else { return }
            Task { await offerOneTimeCode(in: tab, webView: webView, origin: origin) }
        case "submit":
            guard !tab.isPrivate,
                  let username = body["username"] as? String, let password = body["password"] as? String,
                  !password.isEmpty, password.count < 1024, username.count < 512 else { return }
            Task { await offerToSave(origin: origin, username: username, password: password) }
        default:
            break
        }
    }

    func offerAutofill(in tab: Tab, webView: WKWebView, origin: String) async {
        guard !credentialPromptInFlight else { return }
        let logins = (try? vault.logins(forOrigin: origin)) ?? []
        guard !logins.isEmpty else { return }
        credentialPromptInFlight = true
        defer { credentialPromptInFlight = false }

        let host = URL(string: origin)?.host ?? origin
        guard let login = logins.count == 1 ? logins[0] : await chooseLogin(logins, host: host) else { return }
        guard await VaultUnlocker.shared.authenticate(reason: "Remplir le mot de passe de \(login.username) pour \(host)") else { return }
        do {
            guard let password = try vault.password(origin: origin, username: login.username) else { return }
            _ = await webView.safeCall("return window.__hbFill(u, p);", arguments: ["u": login.username, "p": password], world: .page)
        } catch {
            Log.security.error("Autofill failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Le code 2FA d'un compte de ce site (calculé ici, rempli après Touch ID). `manual` : demandé par la personne (palette), donc dit pourquoi s'il n'y a rien à remplir.
    func offerOneTimeCode(in tab: Tab, webView: WKWebView, origin: String, manual: Bool = false) async {
        guard !credentialPromptInFlight else { return }
        let usernames = (try? vault.usernamesWithTOTP(origin: origin)) ?? []
        guard !usernames.isEmpty else { if manual { presentNotice("Aucun code 2FA enregistré pour ce site (Réglages › Mots de passe › 2FA).") }; return }
        credentialPromptInFlight = true
        defer { credentialPromptInFlight = false }
        let host = URL(string: origin)?.host ?? origin
        let logins = usernames.map { SavedLogin(id: 0, origin: origin, username: $0, updatedAt: Date()) }
        guard let login = logins.count == 1 ? logins[0] : await chooseLogin(logins, host: host) else { return }
        guard await VaultUnlocker.shared.authenticate(reason: "Remplir le code 2FA de \(login.username.isEmpty ? host : login.username)") else { return }
        guard let config = try? vault.totp(origin: origin, username: login.username) else { return }
        let ok = await webView.safeCall("return window.__hbFillOTP(c);", arguments: ["c": config.code()], world: .page) as? Bool
        if manual, ok != true { presentNotice("Aucun champ de code à remplir sur cette page.") }
    }

    /// ⌘K › « Remplir le code 2FA ».
    @objc func fillOneTimeCodeAction() {
        guard let tab = activeTab, let webView = tab.webView, !tab.isPrivate, let url = webView.url, url.scheme == "https" || url.scheme == "http" else { return }
        let origin = url.port.map { "\(url.scheme ?? "https")://\(url.host ?? ""):\($0)" } ?? "\(url.scheme ?? "https")://\(url.host ?? "")"
        guard isEligibleForCredentials(origin) else { return }
        Task { await offerOneTimeCode(in: tab, webView: webView, origin: origin, manual: true) }
    }

    func chooseLogin(_ logins: [SavedLogin], host: String) async -> SavedLogin? {
        guard let window else { return nil }
        let alert = NSAlert()
        alert.messageText = "Quel compte utiliser pour « \(host) » ?"
        alert.addButton(withTitle: "Remplir")
        alert.addButton(withTitle: "Annuler")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        popup.addItems(withTitles: logins.map(\.username))
        alert.accessoryView = popup
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        guard response == .alertFirstButtonReturn, logins.indices.contains(popup.indexOfSelectedItem) else { return nil }
        return logins[popup.indexOfSelectedItem]
    }

    func offerToSave(origin: String, username: String, password: String) async {
        let key = "\(origin)\u{0}\(username)"
        guard !credentialPromptInFlight, !declinedSaves.contains(key), let window else { return }
        let existing = try? vault.password(origin: origin, username: username)
        if existing == password { return }

        credentialPromptInFlight = true
        defer { credentialPromptInFlight = false }
        let host = URL(string: origin)?.host ?? origin
        let isUpdate = existing != nil
        let alert = NSAlert()
        alert.messageText = isUpdate ? "Mettre à jour le mot de passe ?" : "Enregistrer le mot de passe ?"
        alert.informativeText = username.isEmpty
            ? "Pour « \(host) ». Il sera chiffré et protégé par Touch ID."
            : "Compte « \(username) » sur « \(host) ». Il sera chiffré et protégé par Touch ID."
        alert.addButton(withTitle: isUpdate ? "Mettre à jour" : "Enregistrer")
        alert.addButton(withTitle: "Pas maintenant")
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        guard response == .alertFirstButtonReturn else { declinedSaves.insert(key); return }
        do {
            try vault.save(origin: origin, username: username, password: password)
        } catch {
            Log.security.error("Saving credential failed: \(String(describing: error), privacy: .public)")
        }
    }
}
