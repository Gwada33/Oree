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

    // MARK: - Flat floating-card helpers

    /// Wraps `inner` in an opaque white, rounded, drop-shadowed card — the
    /// "floating panel" look used throughout this UI. Two layers are needed
    /// because a single layer can't both clip its content to rounded corners
    /// (`masksToBounds`) and cast a shadow outside those same bounds.
    func makeFloatingCard(_ inner: NSView, cornerRadius: CGFloat) -> NSView {
        inner.translatesAutoresizingMaskIntoConstraints = false

        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.backgroundColor = Theme.card.cgColor
        clip.layer?.cornerRadius = cornerRadius
        // HB_NO_CARD_MASK / HB_NO_CARD_SHADOW: A/B switches for measuring what the card chrome costs.
        clip.layer?.masksToBounds = ProcessInfo.processInfo.environment["HB_NO_CARD_MASK"] == nil
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: clip.topAnchor),
            inner.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
        ])

        let shadowHost = NSView()
        shadowHost.wantsLayer = true
        shadowHost.layer?.shadowColor = NSColor.black.cgColor
        shadowHost.layer?.shadowOpacity = ProcessInfo.processInfo.environment["HB_NO_CARD_SHADOW"] == nil ? 0.10 : 0
        shadowHost.layer?.shadowRadius = 14
        shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -3)
        shadowHost.translatesAutoresizingMaskIntoConstraints = false
        shadowHost.addSubview(clip)
        NSLayoutConstraint.activate([
            clip.topAnchor.constraint(equalTo: shadowHost.topAnchor),
            clip.bottomAnchor.constraint(equalTo: shadowHost.bottomAnchor),
            clip.leadingAnchor.constraint(equalTo: shadowHost.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: shadowHost.trailingAnchor),
        ])
        return shadowHost
    }

    // MARK: - UI construction

    /// Window → [sidebar: rail + tab column] | [toolbar over (lisière + page sheet)].
    func buildUI() {
        guard let window else { return }
        applyProfileTitle()
        let contentView = configureWindow(window)
        let sidebar = wireSidebar()
        let bar = wireToolbar()
        buildPageSheet()
        layoutMain(in: contentView, sidebar: sidebar, bar: bar)
        wireAddressBar(in: contentView)
        wireFloatingEdge(in: contentView)
        buildFindBar(in: contentView)

        applySidebarMode(animated: false)
    }

    /// The window itself: transparent title bar, minimum size, the empty toolbar that makes macOS centre the traffic lights; returns its root view.
    private func configureWindow(_ window: NSWindow) -> NSView {

        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 640, height: 480)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        // An empty unified toolbar makes macOS itself center the traffic lights in a 52 pt title row,
        // so they line up with our toolbar (no frame hacks that macOS would undo on the next layout).
        window.toolbar = titleToolbar
        window.toolbarStyle = .unified

        let root = SurfaceView(fill: Theme.chrome)
        root.translatesAutoresizingMaskIntoConstraints = true
        window.contentView = root
        return root
    }

    /// The left dock, its glass backdrop and the handle that resizes it.
    private func wireSidebar() -> NSView {
        let sidebar = buildSidebar()
        sidebarView = sidebar
        (sidebar as? SurfaceView)?.onHover = { [weak self] inside in
            if inside { self?.floatingHideWork?.cancel() } else { self?.scheduleFloatingHide(after: 0.35) }
        }
        let resizeHandleTop = resizeHandle.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: topRow)
        self.resizeHandleTop = resizeHandleTop
        // Liquid Glass backdrop (behind everything) and the drag handle on the right edge.
        sidebarGlassView.translatesAutoresizingMaskIntoConstraints = false
        sidebarGlassView.isHidden = true
        sidebar.addSubview(sidebarGlassView, positioned: .below, relativeTo: nil)
        sidebar.addSubview(resizeHandle)
        NSLayoutConstraint.activate([
            sidebarGlassView.topAnchor.constraint(equalTo: sidebar.topAnchor), sidebarGlassView.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            sidebarGlassView.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor), sidebarGlassView.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            resizeHandleTop, resizeHandle.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            resizeHandle.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor), resizeHandle.widthAnchor.constraint(equalToConstant: 8),
        ])
        resizeHandle.onDrag = { [weak self] x in self?.isResizingSidebar = true; self?.resizeSidebar(toRight: x, final: false) }
        resizeHandle.onEnd = { [weak self] x in self?.resizeSidebar(toRight: x, final: true); self?.isResizingSidebar = false; self?.scheduleFloatingHide(after: 0.6) }
        resizeHandle.onReset = { [weak self] in
            SettingsStore.shared.sidebarWidth = SidebarWidth.standard
            self?.applySidebarMode(animated: true)
        }
        return sidebar
    }

    /// Toolbar buttons, downloads and the address pill's click, plus the appearance observer.
    private func wireToolbar() -> ToolbarView {
        // Toolbar: ← → ↻ · address · customize, more.
        for (button, action) in [(backButton, #selector(goBack)), (forwardButton, #selector(goForward)),
                                 (reloadButton, #selector(reloadAction))] as [(ChromeIconButton, Selector)] {
            button.onClick = { [weak self] in _ = self?.perform(action) }
        }
        toggleSidebarButton.onClick = { [weak self] in
            if self?.isMini == true { self?.moveMiniToMainWindow() } else { self?.toggleSidebar() }
        }
        customizeButton.onClick = { [weak self] in self?.openCustomize() }
        moreButton.onClick = { [weak self] in self?.openPalette(initialText: "", selectAll: false, opensInNewTab: true) }
        addressPill.onClick = { [weak self] in self?.focusAddressBar() }
        addressPill.onIconClick = { [weak self] in self?.showSiteInfo() }
        addressPill.onComplete = { [weak self] typed in self?.inlineCompletion(for: typed) }
        let bar = ToolbarView(pill: addressPill)
        toolbar = bar
        splitButton.onClick = { [weak self] in self?.toggleSplit() }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.settingsChanged() }
        }
        digestButton.onClick = { [weak self] in self?.digestAction() }
        calendarButton.onClick = { [weak self] in self?.addToCalendarAction() }
        nightButton.onClick = { [weak self] in self?.toggleNightForCurrentSite() }
        translateButton.onClick = { [weak self] in self?.translatePageAction() }
        downloadsButton.onClick = { [weak self] in self?.toggleDownloads() }
        downloads.onChange = { [weak self] in self?.downloadsChanged() }
        downloads.onFinish = { [weak self] in
            self?.downloadsButton.pulse()
            self?.journalDownloadFinished()
        }
        downloads.onFinishedFile = { [weak self] file in self?.offerExtensionInstall(fromFile: file) }
        downloads.onStart = { [weak self] in
            guard let self else { return }
            self.downloadsButton.pulse()
            self.journalDownloadStarted()
            // Show the list (once, if it isn't open yet) so the user sees the download begin.
            if self.downloadsPopover?.isShown != true { self.toggleDownloads() }
        }
        downloads.resumeWebView = { [weak self] in self?.activeTab?.webView }
        downloads.start()
        assistantButton.onClick = { [weak self] in self?.askAIAction() }
        widgetTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshWidgets() } }   // les valeurs lues dans la page (pas dans le titre) n'ont pas d'événement : on les relit
        if SettingsStore.shared.lucioleInPage { assistantButton.setCustomContent(assistantMascot); assistantMascot.apply(.sleep) }
        applyChromeLayout()
        return bar
    }

    /// The page sheet and what floats over it: loading bar, essentials, web panel, preview, notices, reading progress.
    private func buildPageSheet() {
        // Page sheet: top-left corner rounded, flush against the right and bottom edges.
        contentContainer.cornerRadius = Theme.pageCornerRadius
        contentContainer.maskedCorners = [.layerMinXMaxYCorner]
        contentContainer.clips = true
        contentContainer.addSubview(loadingBar)
        contentContainer.addSubview(digestPanel)
        NSLayoutConstraint.activate([
            digestPanel.topAnchor.constraint(equalTo: contentContainer.topAnchor), digestPanel.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            digestPanel.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor), digestPanel.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])
        digestPanel.onClose = { [weak self] byUser in
            guard let self else { return }
            self.digestTask?.cancel(); self.digestTask = nil
            if byUser, let key = self.digestKey { self.digestDismissed.insert(key) }       // closed on purpose: not reopened by itself on this page
            self.digestKey = nil
            if let tab = self.activeTab { self.updateDigestButton(for: tab) }
        }
        buildResponsiveBar()
        contentContainer.addSubview(webPanel)
        NSLayoutConstraint.activate([
            webPanel.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 10), webPanel.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -10),
            webPanel.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -10),
        ])
        webPanel.onOpenInTab = { [weak self] url in self?.newTab(urlString: url.absoluteString, isPrivate: false) }
        contentContainer.addSubview(peekPanel)
        NSLayoutConstraint.activate([
            peekPanel.topAnchor.constraint(equalTo: contentContainer.topAnchor), peekPanel.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            peekPanel.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor), peekPanel.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])
        peekPanel.onOpenInTab = { [weak self] url in self?.newTab(urlString: url.absoluteString, isPrivate: self?.activeTab?.isPrivate ?? false) }
        peekPanel.onOpenInMini = { [weak self] url in self?.openMiniWindow(url: url) }
        contentContainer.addSubview(noticePill)
        readingBar.fill = Theme.accent
        readingBar.isHidden = true
        contentContainer.addSubview(readingBar)
        let barWidth = readingBar.widthAnchor.constraint(equalToConstant: 0)
        readingBarWidth = barWidth
        NSLayoutConstraint.activate([
            readingBar.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            readingBar.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            readingBar.heightAnchor.constraint(equalToConstant: 2), barWidth,
        ])
        audioRoute.onChange = { [weak self] in self?.refreshNowPlaying() }
        audioRoute.start()
        NSLayoutConstraint.activate([
            noticePill.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            noticePill.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -24),
        ])
        NSLayoutConstraint.activate([
            loadingBar.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            loadingBar.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            loadingBar.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            loadingBar.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    /// Puts the bars, the sheet and the sidebar in the window and pins them (the sidebar goes last so, floating, it overlays the page).
    private func layoutMain(in contentView: NSView, sidebar: NSView, bar: ToolbarView) {
        [tabStrip, bar, contentContainer, sidebar].forEach(contentView.addSubview)
        contentView.addLayoutGuide(mainGuide)
        let mainLead = mainGuide.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: expandedSidebarWidth)
        mainLeading = mainLead
        let sideLead = sidebar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        let sidebarTopConstraint = sidebar.topAnchor.constraint(equalTo: contentView.topAnchor)
        let sidebarBottomConstraint = sidebar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        sidebarTop = sidebarTopConstraint
        sidebarBottom = sidebarBottomConstraint
        sidebarLeading = sideLead

        let width = sidebar.widthAnchor.constraint(equalToConstant: expandedSidebarWidth)
        sidebarWidth = width
        let stripH = tabStrip.heightAnchor.constraint(equalToConstant: 0)
        stripHeight = stripH
        stripH.isActive = true
        tabStrip.spaceChip.onClick = { [weak self] in self?.openOverview() }
        tabStrip.newTabButton.onClick = { [weak self] in self?.newTabAction() }
        tabStrip.overflowButton.onClick = { [weak self] in self?.showAllTabsMenu() }
        NSLayoutConstraint.activate([
            sidebarTopConstraint, sidebarBottomConstraint,
            sideLead, mainLead,
            mainGuide.widthAnchor.constraint(equalToConstant: 0),
            width,

            tabStrip.topAnchor.constraint(equalTo: contentView.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bar.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: mainGuide.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            contentContainer.topAnchor.constraint(equalTo: bar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: mainGuide.leadingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        let pageEdge = contentContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        pageEdge.isActive = true
        pageTrailing = pageEdge
    }

    /// The suggestions under the address bar and the bar's editing callbacks.
    private func wireAddressBar(in contentView: NSView) {
        contentView.addSubview(addressDropdown)
        NSLayoutConstraint.activate([
            addressDropdown.topAnchor.constraint(equalTo: addressPill.bottomAnchor, constant: 6),
            addressDropdown.leadingAnchor.constraint(equalTo: addressPill.leadingAnchor),
            addressDropdown.trailingAnchor.constraint(equalTo: addressPill.trailingAnchor),
        ])
        addressPill.onTextChange = { [weak self] text in self?.refreshAddressSuggestions(text) }
        addressPill.onMove = { [weak self] delta in self?.addressDropdown.move(delta) }
        addressPill.onEndEditing = { [weak self] in self?.endAddressEditing() }
        addressPill.onCommit = { [weak self] text, newTab in self?.commitAddress(text, newTab: newTab) }
        addressDropdown.onPick = { [weak self] item in
            self?.endAddressEditing()
            item.perform(false)
        }
    }

    /// The strip on the left edge that reveals the floating sidebar, and the menu-tracking guards that keep it from hiding mid-click.
    private func wireFloatingEdge(in contentView: NSView) {
        contentView.addSubview(edgeTrigger)
        edgeTrigger.onReveal = { [weak self] in self?.scheduleFloatingShow() }
        edgeTrigger.onLeave = { [weak self] in self?.floatingShowWork?.cancel() }
        let center = NotificationCenter.default
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.floatingMenuTracking = true; self?.floatingHideWork?.cancel() }
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.floatingMenuTracking = false; self?.scheduleFloatingHide(after: 0.8) }
        }
        NSLayoutConstraint.activate([
            edgeTrigger.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            edgeTrigger.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 60),
            edgeTrigger.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            edgeTrigger.widthAnchor.constraint(equalToConstant: 10),
        ])
    }

    /// Left dock: a 44 pt row for the traffic lights, then the space rail and the tab column
    /// (space name, search, new tab, favorites, tabs — one scroll so long lists scroll in place).
    func buildSidebar() -> NSView {
        let sidebar = SurfaceView()
        sidebar.setAccessibilityElement(true)
        sidebar.setAccessibilityRole(.group)
        sidebar.setAccessibilityLabel("Barre latérale")

        spaceRail.onSelect = { [weak self] in self?.selectSpace($0) }
        spaceRail.onRename = { [weak self] in self?.renameSpace($0) }
        spaceRail.onNewSpace = { [weak self] in self?.addSpace() }
        spaceRail.onOverview = { [weak self] in self?.openOverview() }
        spaceRail.onSettings = { [weak self] in self?.openSettings() }
        collapseButton.onClick = { [weak self] in self?.toggleCompactSidebar() }

        let column = SurfaceView()
        let columnTopConstraint = column.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: topRow)
        columnTop = columnTopConstraint
        spaceNameLabel.font = Theme.Typo.subheading
        spaceNameLabel.textColor = Theme.text
        spaceMetaLabel.font = Theme.sans(12)
        spaceMetaLabel.textColor = Theme.muted
        hoverSpaceRow.orientation = .horizontal
        hoverSpaceRow.spacing = 4
        hoverSpaceRow.alignment = .centerY
        hoverSpaceRow.translatesAutoresizingMaskIntoConstraints = false
        hoverSpaceRow.isHidden = true
        let header = NSStackView(views: [spaceNameLabel, spaceMetaLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2
        header.translatesAutoresizingMaskIntoConstraints = false
        let topStack = NSStackView(views: [hoverSpaceRow, header])
        topStack.orientation = .vertical
        topStack.alignment = .leading
        topStack.spacing = 8
        topStack.translatesAutoresizingMaskIntoConstraints = false

        let searchRow = SidebarRowView(symbol: "magnifyingglass", title: "Rechercher, aller à…", shortcut: "⌘K")
        searchRow.onClick = { [weak self] in self?.openPalette(initialText: "", selectAll: false, opensInNewTab: true) }
        let newTabRow = SidebarRowView(symbol: "plus", title: "Nouvel onglet", shortcut: "⌘T")
        newTabRow.onClick = { [weak self] in self?.newTabAction() }
        self.searchRow = searchRow
        self.newTabRow = newTabRow

        favoritesStack.orientation = .vertical
        favoritesStack.spacing = 6
        favoritesStack.alignment = .leading
        favoritesStack.translatesAutoresizingMaskIntoConstraints = false

        tabBarStack.orientation = .vertical
        tabBarStack.spacing = 2
        tabBarStack.distribution = .fill
        tabBarStack.alignment = .width
        tabBarStack.translatesAutoresizingMaskIntoConstraints = false
        tabBarStack.setAccessibilityElement(true)
        tabBarStack.setAccessibilityRole(.list)
        tabBarStack.setAccessibilityLabel("Onglets ouverts")

        extensionBar.orientation = .horizontal
        extensionBar.spacing = 2
        extensionBar.alignment = .centerY
        extensionBar.translatesAutoresizingMaskIntoConstraints = false
        extensionBar.isHidden = true
        extensionBar.setAccessibilityLabel("Extensions")
        let body = NSStackView(views: [extensionBar, favoritesStack, tabBarStack])
        body.orientation = .vertical
        body.spacing = 10
        body.alignment = .leading
        body.translatesAutoresizingMaskIntoConstraints = false
        for view in [extensionBar, favoritesStack, tabBarStack] {
            view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = FlippedDocumentView()
        let document = scroll.documentView!
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            body.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        // Bottom bar: Favoris · Historique · Téléchargements · Liste de lecture, "N en veille" at the right.
        let panelBar = NSStackView()
        panelBar.orientation = .horizontal; panelBar.alignment = .centerY; panelBar.spacing = 2
        panelBar.translatesAutoresizingMaskIntoConstraints = false
        panelBar.addArrangedSubview(NSView())   // placeholder removed below
        panelBar.arrangedSubviews.forEach { panelBar.removeArrangedSubview($0); $0.removeFromSuperview() }
        let kinds: [(PanelKind, String, String)] = [(.favorites, "star", "Favoris"), (.history, "clock", "Historique  ⌘Y"),
                                                    (.downloads, "arrow.down.to.line", "Téléchargements"), (.reading, "text.book.closed", "Liste de lecture")]
        for (kind, symbol, label) in kinds {
            let b = ChromeIconButton(symbol: symbol, label: label, size: 30, pointSize: 13)
            b.onClick = { [weak self] in self?.togglePanel(kind) }
            panelButtons.append((kind, b))
            panelBar.addArrangedSubview(b)
        }
        let spacer = NSView(); spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        panelBar.addArrangedSubview(spacer)
        sleepMetaLabel.font = Theme.sans(11.5); sleepMetaLabel.textColor = Theme.muted
        sleepMetaLabel.translatesAutoresizingMaskIntoConstraints = false
        panelBar.addArrangedSubview(sleepMetaLabel)
        sidePanel.onBack = { [weak self] in self?.togglePanel(nil) }
        footerStack = panelBar
        footerTail = [spacer, sleepMetaLabel]
        applyChromeLayout()

        [topStack, searchRow, newTabRow, scroll, sidePanel, widgetStrip, nowPlaying, panelBar].forEach(column.addSubview)
        let rowsInset: CGFloat = 8
        NSLayoutConstraint.activate([
            topStack.topAnchor.constraint(equalTo: column.topAnchor, constant: 8),
            topStack.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 10),
            topStack.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor, constant: -10),

            searchRow.topAnchor.constraint(equalTo: topStack.bottomAnchor, constant: 12),
            searchRow.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: rowsInset),
            searchRow.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -rowsInset),
            newTabRow.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 2),
            newTabRow.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor),
            newTabRow.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: newTabRow.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: rowsInset),
            scroll.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -rowsInset),
            scroll.bottomAnchor.constraint(equalTo: widgetStrip.topAnchor),
            widgetStrip.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: rowsInset),
            widgetStrip.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -rowsInset),
            widgetStrip.bottomAnchor.constraint(equalTo: nowPlaying.topAnchor),
            nowPlaying.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: rowsInset),
            nowPlaying.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -rowsInset),
            nowPlaying.bottomAnchor.constraint(equalTo: panelBar.topAnchor, constant: -6),

            panelBar.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: rowsInset),
            panelBar.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -rowsInset),
            panelBar.bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: -10),
            panelBar.heightAnchor.constraint(equalToConstant: 34),

            sidePanel.topAnchor.constraint(equalTo: newTabRow.bottomAnchor, constant: 10),
            sidePanel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            sidePanel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            sidePanel.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
        ])
        tabColumn = column
        panelScroll = scroll

        [spaceRail, column, collapseButton].forEach(sidebar.addSubview)
        let rail = spaceRail.widthAnchor.constraint(equalToConstant: CGFloat(OreeTokens.Metrics.railWidth))
        railWidth = rail
        NSLayoutConstraint.activate([
            spaceRail.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            spaceRail.topAnchor.constraint(equalTo: sidebar.topAnchor),
            spaceRail.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            rail,

            column.leadingAnchor.constraint(equalTo: spaceRail.trailingAnchor),
            column.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            columnTopConstraint,
            column.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),

            collapseButton.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            collapseButton.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 12),
        ])

        refreshPinnedIcons()
        return sidebar
    }
}
