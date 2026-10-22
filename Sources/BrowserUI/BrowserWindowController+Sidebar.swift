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

    // MARK: - Sidebar modes

    /// What is actually shown: the chosen mode, except that narrow windows fall back to compact.
    var effectiveSidebarMode: SidebarMode {
        isMini ? .hidden : BrowserCore.effectiveSidebarMode(SettingsStore.shared.sidebarMode, windowWidth: Double(window?.frame.width ?? 1280))
    }


    func applySidebarMode(animated: Bool) {
        let store = SettingsStore.shared
        let horizontal = store.tabLayout == .horizontal && !isMini
        let mode: SidebarMode = horizontal ? .hidden : effectiveSidebarMode
        let compact = mode == .compact
        let hover = mode == .floating                          // hidden until the pointer touches the left edge
        let hidden = mode == .hidden
        let outOfLayout = hidden || hover                      // sidebar is not a column of the layout
        // Title row: 52 pt with the system-centered traffic lights; 44 pt in full screen (no lights, no title bar).
        let bar = isFullScreen ? CGFloat(OreeTokens.Metrics.stackedToolbarHeight) : CGFloat(OreeTokens.Metrics.toolbarHeight)
        spaceRail.setTopInset(isFullScreen ? 10 : bar)
        columnTop?.constant = isFullScreen ? 10 : bar
        resizeHandleTop?.constant = isFullScreen ? 10 : bar
        stripHeight?.constant = horizontal ? bar : 0
        toolbar.setHeight(horizontal ? CGFloat(OreeTokens.Metrics.stackedToolbarHeight) : bar)
        tabStrip.isHidden = !horizontal
        tabStrip.setLeadingInset(isFullScreen ? 12 : 92)
        // Hover panel is the concise version: no 52 pt rail, spaces become a row of icons, so it is narrower.
        let railW = CGFloat(OreeTokens.Metrics.railWidth)
        let width: CGFloat = compact ? CGFloat(OreeTokens.Metrics.compactSidebarWidth) + 2
            : hover ? max(expandedSidebarWidth - railW, CGFloat(SidebarWidth.minimum) - railW) : expandedSidebarWidth
        if !hover {
            floatingShown = false
            floatingShowWork?.cancel(); floatingHideWork?.cancel()
            if let monitor = floatingClickMonitor { NSEvent.removeMonitor(monitor); floatingClickMonitor = nil }
        }
        spaceRail.configure(spaces: spaces, selected: currentSpace, compact: compact)
        spaceRail.isHidden = hover
        refreshHoverSpaceRow()
        hoverSpaceRow.isHidden = !hover
        updateTabCount()
        railWidth?.constant = compact ? width : (hover ? 0 : railW)
        tabColumn?.isHidden = compact
        collapseButton.isHidden = compact || hidden || hover
        collapseButton.toolTip = "Réduire la barre latérale"
        resizeHandle.isHidden = compact || hidden
        // The toolbar's sidebar button: brings back a hidden / hover / compact sidebar.
        let showToggle = isMini || (!horizontal && (hidden || hover || store.sidebarMode == .compact))
        setRelevant(.sidebarToggle, showToggle)
        if !isMini { toggleSidebarButton.toolTip = compact ? "Agrandir la barre latérale  ⌥⌘S" : "Afficher la barre latérale  ⌥⌘S" }
        let lightsClear: CGFloat = isFullScreen ? 12 : 92                            // room for the traffic lights when the toolbar starts at x = 0
        // Compact: the toolbar starts at the 58 pt rail, so its first button needs less inset to clear the lights.
        toolbar.setLeadingInset(horizontal ? 8 : (hidden || hover) ? lightsClear : (compact ? max(lightsClear - 58, 8) : 8))
        edgeTrigger.isHidden = !hover
        let visibleOverlay = hover && floatingShown

        // Surface: a rounded, inset glass (or solid) panel while it hovers over the page; edge-to-edge otherwise.
        let glass = hover && store.sidebarGlass
        let inset: CGFloat = hover ? 8 : 0
        sidebarGlassView.isHidden = !glass
        if let surface = sidebarView as? SurfaceView {
            surface.fill = (hover && !glass) ? Theme.chrome : nil
            surface.cornerRadius = hover ? 20 : 0
            surface.clips = hover
            surface.border = hover ? Theme.line : nil
            surface.elevation = nil
        }
        sidebarTop?.constant = inset
        sidebarBottom?.constant = -inset
        Motion.animate(animated ? Motion.slow : 0) {
            let w = animated ? sidebarWidth?.animator() : sidebarWidth
            w?.constant = width
            (animated ? mainLeading?.animator() : mainLeading)?.constant = outOfLayout ? 0 : width
            let hiddenOffset = -(width + 40)
            (animated ? sidebarLeading?.animator() : sidebarLeading)?.constant = visibleOverlay ? inset : (outOfLayout ? hiddenOffset : 0)
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// Compact row of space icons (+ overview) shown at the top of the hover panel instead of the rail.
    func refreshHoverSpaceRow() {
        hoverSpaceRow.arrangedSubviews.forEach { hoverSpaceRow.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (index, space) in spaces.enumerated() {
            let spine = SpineButton(space: space, shortcut: "⌃\(index + 1)")
            spine.iconOnly = true
            spine.isSelected = index == currentSpace
            spine.onClick = { [weak self] in self?.selectSpace(index) }
            spine.contextMenuProvider = { [weak self] in
                let menu = NSMenu()
                menu.addItem(ClosureMenuItem(title: "Modifier l’espace…") { self?.openOverview() })
                return menu
            }
            hoverSpaceRow.addArrangedSubview(spine)
        }
        let overview = ChromeIconButton(symbol: "square.grid.2x2", label: "Vue d’ensemble des espaces  ⌃↑", size: 36, pointSize: 14)
        overview.onClick = { [weak self] in self?.openOverview() }
        hoverSpaceRow.addArrangedSubview(overview)
        let settings = ChromeIconButton(symbol: "gearshape", label: "Réglages  ⇧⌘,", size: 36, pointSize: 14)
        settings.onClick = { [weak self] in self?.openSettings() }
        hoverSpaceRow.addArrangedSubview(settings)
    }

    /// Live resize while the handle is dragged; the width is saved when released.
    func resizeSidebar(toRight x: CGFloat, final: Bool) {
        guard let sidebar = sidebarView else { return }
        let left = sidebar.frame.minX
        let width = CGFloat(SidebarWidth.clamp(Double(x - left)))
        sidebarWidth?.constant = width
        if !effectiveSidebarMode.overlaysPage { mainLeading?.constant = width }
        window?.contentView?.layoutSubtreeIfNeeded()
        if final { SettingsStore.shared.sidebarWidth = Double(width) }
    }

    // MARK: Hover sidebar

    var pointerInSidebar: Bool {
        guard let window, let sidebar = sidebarView, let content = window.contentView else { return false }
        let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return sidebar.frame.insetBy(dx: -4, dy: -4).contains(point)
    }

    var pointerInEdgeZone: Bool {
        guard let window, let content = window.contentView else { return false }
        let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return edgeTrigger.frame.insetBy(dx: -2, dy: 0).contains(point)
    }

    /// The pointer touched the left edge: show the panel if it is still there after a short moment (not when merely passing by).
    func scheduleFloatingShow() {
        guard effectiveSidebarMode == .floating, !floatingShown else { return }
        floatingShowWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            mainActorNow {
                guard let self, self.pointerInEdgeZone else { return }
                self.setFloatingShown(true)
                self.scheduleFloatingHide(after: 1.5)       // safety net if the pointer never enters the panel
            }
        }
        floatingShowWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Hides the panel after `delay`, unless the pointer is back on it, a menu is open or its edge is being dragged.
    func scheduleFloatingHide(after delay: TimeInterval) {
        guard floatingShown else { return }
        floatingHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            mainActorNow {
                guard let self, self.floatingShown else { return }
                if self.pointerInSidebar || self.pointerInEdgeZone || self.floatingMenuTracking || self.isResizingSidebar { return }
                self.setFloatingShown(false)
            }
        }
        floatingHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Slides the panel in or out. Only the position moves — nothing is rebuilt, so there is no flicker.
    func setFloatingShown(_ shown: Bool) {
        guard effectiveSidebarMode == .floating, floatingShown != shown else { return }
        floatingShown = shown
        floatingShowWork?.cancel(); floatingHideWork?.cancel()
        let width = sidebarWidth?.constant ?? expandedSidebarWidth
        let target: CGFloat = shown ? 8 : -(width + 40)
        Motion.animate(shown ? Motion.standard : Motion.quick) {
            sidebarLeading?.animator().constant = target
            window?.contentView?.layoutSubtreeIfNeeded()
        }
        if shown {
            // A click anywhere outside the panel puts it away (the click still goes through to the page).
            floatingClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                mainActorNow {
                    guard let self, let content = self.window?.contentView, event.window === self.window,
                          let sidebar = self.sidebarView else { return }
                    let point = content.convert(event.locationInWindow, from: nil)
                    if !sidebar.frame.contains(point) { self.setFloatingShown(false) }
                }
                return event
            }
        } else if let monitor = floatingClickMonitor {
            NSEvent.removeMonitor(monitor)
            floatingClickMonitor = nil
        }
    }

    /// ⌘⇧S / ⌥⌘S: hide or bring back the sidebar (in floating mode: show or tuck away the overlay).
    @objc func toggleSidebar() {
        let store = SettingsStore.shared
        if store.tabLayout == .horizontal { return }
        if store.sidebarMode == .floating { setFloatingShown(!floatingShown); return }
        if store.sidebarMode == .compact { store.sidebarMode = .fixed; applySidebarMode(animated: true); return }
        if store.sidebarMode == .hidden {
            let back = SidebarMode(rawValue: UserDefaults.standard.string(forKey: "sidebar.modeBeforeHide") ?? "") ?? .fixed
            store.sidebarMode = back == .hidden ? .fixed : back
        } else {
            UserDefaults.standard.set(store.sidebarMode.rawValue, forKey: "sidebar.modeBeforeHide")
            store.sidebarMode = .hidden
        }
        applySidebarMode(animated: true)
    }

    /// The button in the sidebar header: icons-only ↔ full width.
    func toggleCompactSidebar() {
        let store = SettingsStore.shared
        if store.sidebarMode == .floating { store.sidebarMode = .fixed; applySidebarMode(animated: true); return }
        store.sidebarMode = (store.sidebarMode == .compact) ? .fixed : .compact
        applySidebarMode(animated: true)
    }

    /// Automation only: puts the first two tabs of the space into a "Recherche" group.
    @objc func automationDemoGroup() {
        let group = TabGroup(name: "Recherche", spaceIndex: currentSpace)
        groups.append(group)
        for tab in visibleTabs().prefix(2) { tab.groupID = group.id }
        rebuildTabList()
        saveSession()
    }

    /// Automation only: collapses/expands the first group.
    @objc func automationToggleFirstGroup() { if let g = groups.first { toggleGroup(g.id) } }

    /// Automation only: shrinks the window to exercise the narrow (auto-compact) layout.
    /// Automation only: where the traffic lights really are (window coordinates, from the top).
    @objc func automationLights() {
        guard let window else { return }
        var text = "windowH=\(window.frame.height) layoutRect=\(window.contentLayoutRect)\n"
        for type in [NSWindow.ButtonType.closeButton, .zoomButton] {
            guard let b = window.standardWindowButton(type), let sv = b.superview else { continue }
            let inWindow = sv.convert(b.frame, to: nil)
            text += "\(type.rawValue): centerFromTop=\(window.frame.height - inWindow.midY) frame=\(b.frame) bar=\(sv.frame) \(sv.className) container=\(String(describing: sv.superview?.frame))\n"
        }
        try? text.write(toFile: "/tmp/hb-lights.txt", atomically: true, encoding: .utf8)
    }

    @objc func automationDownloadsPanelDemo() {
        guard let content = window?.contentView else { return }
        demoPanel?.removeFromSuperview()
        let panel = DownloadsPanelView(controller: downloads)
        panel.wantsLayer = true
        panel.layer?.backgroundColor = Theme.cg(Theme.raised, in: panel)
        panel.layer?.cornerRadius = 14
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = Theme.cg(Theme.line, in: panel)
        content.addSubview(panel)
        NSLayoutConstraint.activate([panel.topAnchor.constraint(equalTo: content.topAnchor, constant: 60), panel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16)])
        demoPanel = panel
        downloads.onChange = { [weak self] in self?.downloadsChanged(); self?.demoPanel?.refresh() }
    }

    @objc func automationDownloadsDump() { try? downloads.debugDescription().write(toFile: "/tmp/hb-downloads.txt", atomically: true, encoding: .utf8) }
    @objc func automationPauseDownload() { if let id = downloads.debugFirstID() { downloads.pause(id) } }
    @objc func automationResumeDownload() { if let id = downloads.debugFirstID() { downloads.resume(id) } }
    @objc func automationCancelDownload() { if let id = downloads.debugFirstID() { downloads.cancel(id) } }

    @objc func automationBraveDiag() {
        try? ChromiumCookies.diagnose().joined(separator: "\n").write(toFile: "/tmp/hb-brave-diag.txt", atomically: true, encoding: .utf8)
    }

    @objc func automationNarrowWindow() {
        guard var frame = window?.frame else { return }
        frame.size.width = 820
        window?.setFrame(frame, display: true)
    }

    // Full screen has no title bar: drop the (empty) toolbar that would otherwise slide down over our own,
    // and use the compact 44 pt title row. Both come back when leaving full screen.
    public func windowWillEnterFullScreen(_ notification: Notification) {
        isFullScreen = true
        window?.toolbar = nil
        applySidebarMode(animated: false)
    }
    public func windowDidEnterFullScreen(_ notification: Notification) { settleLayout() }
    public func windowWillExitFullScreen(_ notification: Notification) {
        isFullScreen = false
        window?.toolbar = titleToolbar
        window?.toolbarStyle = .unified
        applySidebarMode(animated: false)
    }
    public func windowDidExitFullScreen(_ notification: Notification) {
        // The title bar only takes the toolbar once the transition is over; re-attach it so the traffic lights re-center.
        isFullScreen = false
        window?.toolbar = nil
        window?.toolbar = titleToolbar
        window?.toolbarStyle = .unified
        settleLayout()
    }

    public func windowDidResize(_ notification: Notification) {
        applySidebarMode(animated: false)
        journalLayoutSoon()
        if let tab = activeTab, tab.responsive != nil { applyResponsive(tab.responsive, to: tab, reload: false) }
        if windowExceedsScreen() { DispatchQueue.main.async { [weak self] in self?.clampWindowToScreen() } }
    }

    public func windowDidChangeScreen(_ notification: Notification) { settleLayout() }

    // MARK: Retour du plein écran : tout remettre d'aplomb

    /// AppKit finit d'attacher la barre de titre et de rendre ses dimensions à la fenêtre un peu après `windowDidExitFullScreen` : le mode compact
    /// (rail, décalage des boutons) et la page doivent être recalculés une fois la transition vraiment terminée, pas seulement à son annonce.
    func settleLayout() {
        relayoutWindow()
        for delay in [0.12, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.relayoutWindow() }
        }
    }

    func relayoutWindow() {
        clampWindowToScreen()
        applySidebarMode(animated: false)
        contentContainer.needsLayout = true
        window?.contentView?.layoutSubtreeIfNeeded()
        activeTab?.webView?.needsLayout = true
    }

    func windowExceedsScreen() -> Bool {
        guard let window, !window.styleMask.contains(.fullScreen), !isFullScreen, let visible = window.screen?.visibleFrame else { return false }
        return window.frame.width > visible.width + 1 || window.frame.height > visible.height + 1
    }

    /// Une fenêtre ne doit jamais être plus grande que l'écran qui la porte (une page qui impose une largeur, un retour du plein écran mal
    /// terminé, un écran débranché…) : sinon la page déborde et on ne peut plus attraper les bords.
    func clampWindowToScreen() {
        guard windowExceedsScreen(), let window, let visible = window.screen?.visibleFrame else { return }
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
        window.setFrame(frame, display: true)
    }

    @objc func automationHugeWindow() {
        guard var frame = window?.frame else { return }
        frame.size.width = 6000
        window?.setFrame(frame, display: true)
    }

    /// Favorites grid: three equal columns right under the search field.
    func refreshPinnedIcons() {
        favoritesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let bookmarks = (try? bookmarkRepo.all(forSpace: currentSpace)) ?? []

        // One cell per favorite, plus a final "+" cell that adds the current page.
        var cells: [NSView] = bookmarks.map { bookmark in
            let tile = FavoriteTileView(url: bookmark.url, title: bookmark.title)
            tile.onClick = { [weak self] in self?.newTab(urlString: bookmark.url, isPrivate: false) }
            tile.contextMenuProvider = { [weak self] in self?.makeFavoriteMenu(for: bookmark) }
            return tile
        }
        let addTile = AddFavoriteTileView()
        addTile.onClick = { [weak self] in
            guard let self, let tab = self.activeTab else { return }
            self.toggleBookmark(for: tab, forceAdd: true)
        }
        cells.append(addTile)

        var delay = 0.0
        for start in stride(from: 0, to: cells.count, by: 4) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            for column in 0..<4 {
                guard start + column < cells.count else {
                    row.addArrangedSubview(NSView())   // keeps the last row's tiles the same width
                    continue
                }
                let cell = cells[start + column]
                cell.alphaValue = 0
                Motion.animate(Motion.standard + delay) { cell.animator().alphaValue = 1 }
                delay += 0.02
                row.addArrangedSubview(cell)
            }
            favoritesStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: favoritesStack.widthAnchor).isActive = true
        }
    }

    func makeFavoriteMenu(for bookmark: Bookmark) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping @MainActor () -> Void) {
            menu.addItem(ClosureMenuItem(title: title, action: action))
        }
        add("Ouvrir dans un nouvel onglet") { [weak self] in self?.newTab(urlString: bookmark.url, isPrivate: false) }
        add("Copier le lien") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(bookmark.url, forType: .string)
        }
        menu.addItem(.separator())
        add("Retirer des favoris") { [weak self] in
            try? self?.bookmarkRepo.remove(url: bookmark.url)
            self?.menuBuilder?.refreshBookmarksMenu()
            self?.refreshPinnedIcons()
        }
        return menu
    }

    /// Adds the tab's page to the favorites, or removes it if it's already there
    /// (`forceAdd` never removes — used by the "+" tile).
    func toggleBookmark(for tab: Tab, forceAdd: Bool = false) {
        guard let url = tab.currentURL, url.scheme == "http" || url.scheme == "https" else { return }
        let key = url.absoluteString
        do {
            if try bookmarkRepo.contains(url: key) {
                guard !forceAdd else { return }
                try bookmarkRepo.remove(url: key)
                SpotlightIndexer.shared.remove(url: key)
            } else {
                try bookmarkRepo.add(url: key, title: tab.displayTitle, spaceIndex: currentSpace)
                SpotlightIndexer.shared.addBookmark(url: key, title: tab.displayTitle)
            }
        } catch {
            Log.storage.error("Failed to toggle bookmark: \(error.localizedDescription)")
        }
        menuBuilder?.refreshBookmarksMenu()
        refreshPinnedIcons()
    }
}
