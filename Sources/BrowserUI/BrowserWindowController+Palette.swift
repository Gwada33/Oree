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

    // MARK: - Command palette

    /// ⌘Y — the palette, already filtered on history.
    @objc func openHistoryAction() {
        palette.present(initialText: "", selectAll: false, opensInNewTab: true, in: window)
        palette.setFilter(.history)
    }

    /// ⇧⌘L — Clair → Sombre → Auto.
    @objc func cycleTheme() {
        let all = AppearanceMode.allCases
        let store = SettingsStore.shared
        store.appearanceMode = all[((all.firstIndex(of: store.appearanceMode) ?? 0) + 1) % all.count]
        applyLookChanges()
        if drawerLoaded { drawer.refreshFromSettings() }
    }

    /// ⌘K
    @objc func openPaletteAction() {
        openPalette(initialText: "", selectAll: false, opensInNewTab: true)
    }

    /// ⌘L — edit the address in the toolbar, with suggestions underneath.
    @objc func focusAddressBar() {
        if drawerLoaded, drawer.isPresented { closeCustomize() }
        journalAddressFocused(how: "shortcut")
        let url = activeTab?.currentURL
        let text = (url?.scheme == "http" || url?.scheme == "https") ? (url?.absoluteString ?? "") : ""
        addressPill.beginEditing(text: text)
    }

    func refreshAddressSuggestions(_ query: String) {
        let sections = paletteSections(query: query.trimmingCharacters(in: .whitespacesAndNewlines), filter: .all)
            .filter { $0.title != "Actions" && $0.title != "Espaces" && $0.title != "Favoris" }
        journalAddressTyped(query, sections: sections)
        addressDropdown.show(sections)
    }

    /// What the address bar can finish `typed` with, from the favorites and the history (most visited first).
    func inlineCompletion(for typed: String) -> String? {
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { return nil }
        let favorites = ((try? bookmarkRepo.all()) ?? []).map(\.url)
        let visited = (try? historyRepo.addresses(containing: text.components(separatedBy: "/").first ?? text)) ?? []
        return InlineCompletion.completion(for: typed, candidates: favorites + visited)
    }

    func endAddressEditing() {
        journalAddressEnded()
        addressPill.endEditing()
        addressDropdown.hide()
        if let webView = activeTab?.webView, window?.firstResponder is NSText || window?.firstResponder === window { window?.makeFirstResponder(webView) }
    }

    func commitAddress(_ text: String, newTab: Bool) {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Like the palette: Return runs the highlighted suggestion (the first one unless arrowed).
        if let item = addressDropdown.selectedItem, addressDropdown.hasSelection, !raw.isEmpty {
            journalAddressCommitted(kind: "suggestion", index: addressDropdown.selectedIndex, newTab: newTab)
            endAddressEditing(); item.perform(newTab); return
        }
        journalAddressCommitted(kind: addressDropdown.hasSelection ? "other" : (AddressResolver.resolve(raw, defaultEngine: SettingsStore.shared.searchEngine, custom: SettingsStore.shared.customSearchShortcuts) == nil ? "url" : "search"), index: -1, newTab: newTab)
        endAddressEditing()
        guard !raw.isEmpty else { return }
        openFromPalette(raw, inNewTab: newTab)
    }

    func openPalette(initialText: String, selectAll: Bool, opensInNewTab: Bool) {
        journalPanel("palette", open: true)
        palette.present(initialText: initialText, selectAll: selectAll, opensInNewTab: opensInNewTab, in: window)
    }

    func closePalette() {
        palette.dismiss(restoringFocusTo: activeTab?.webView)
    }

    func openFromPalette(_ raw: String, inNewTab: Bool) {
        if inNewTab || activeTab == nil {
            journalOpenHow = "palette"
            newTab(urlString: raw, isPrivate: SettingsStore.shared.privateByDefault)
        } else if let tab = activeTab {
            load(urlString: raw, in: tab)
        }
    }

    func paletteSections(query: String, filter: PaletteFilter) -> [PaletteSection] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ values: String...) -> Bool {
            q.isEmpty || values.contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        var sections: [PaletteSection] = []

        if filter == .all, let value = Calculator.evaluate(q) {
            let answer = Calculator.format(value)
            sections.append(PaletteSection(title: "Calcul", items: [
                PaletteItem(icon: .symbol("equal.square"), title: "= \(answer)", subtitle: q, trailing: "↵ copier", perform: { [weak self] _ in
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(answer, forType: .string)
                    self?.presentNotice("« \(answer) » copié.")
                }),
            ]))
        }

        if filter == .all, !q.isEmpty {
            let resolution = AddressResolver.resolve(q, defaultEngine: SettingsStore.shared.searchEngine, custom: SettingsStore.shared.customSearchShortcuts)
            var siteName: String?
            if case .search(let site, _)? = resolution { siteName = site }
            let isAddress = siteName == nil
            sections.append(PaletteSection(title: isAddress ? "Ouvrir" : "Rechercher", items: [
                PaletteItem(
                    icon: .symbol(isAddress ? "arrow.up.right" : "magnifyingglass"),
                    title: isAddress ? q : "« \(q) » sur \(siteName ?? "le web")",
                    subtitle: nil,
                    trailing: "↵",
                    perform: { [weak self] inNewTab in self?.openFromPalette(q, inNewTab: inNewTab) }
                ),
            ]))
        }

        if filter == .all || filter == .tabs {
            let found = tabs.filter { matches($0.displayTitle, $0.currentURL?.absoluteString ?? "") }
            sections.append(PaletteSection(title: "Onglets ouverts", items: found.map { tab in
                PaletteItem(
                    icon: .site(host: tab.badgeHost.isEmpty ? tab.displayTitle : tab.badgeHost),
                    title: tab.displayTitle,
                    subtitle: [tab.badgeHost.isEmpty ? nil : tab.badgeHost, tab.spaceIndex == currentSpace ? nil : spaces[min(tab.spaceIndex, spaces.count - 1)].name].compactMap { $0 }.joined(separator: " · "),
                    trailing: tab.id == activeTabID ? "actif" : "Basculer",
                    perform: { [weak self, weak tab] _ in if let tab { self?.selectTab(tab) } }
                )
            }))
        }

        let favorites = ((try? bookmarkRepo.all()) ?? []).filter { matches($0.title, $0.url) }
        if filter == .all || filter == .bookmarks {
            sections.append(PaletteSection(title: "Favoris", items: favorites.prefix(filter == .all ? 4 : 30).map { bookmark in
                PaletteItem(
                    icon: .site(host: URL(string: bookmark.url)?.host ?? bookmark.url),
                    title: bookmark.title.isEmpty || bookmark.title == bookmark.url
                        ? (URL(string: bookmark.url)?.host ?? bookmark.url) : bookmark.title,
                    subtitle: bookmark.url,
                    trailing: nil,
                    perform: { [weak self] inNewTab in self?.openFromPalette(bookmark.url, inNewTab: inNewTab) }
                )
            }))
        }

        if filter == .all || filter == .history {
            let favoriteURLs = Set(favorites.map(\.url))
            let entries: [(url: String, title: String, date: Date?)]
            if q.isEmpty {
                entries = ((try? historyRepo.recent(limit: 6)) ?? []).map { ($0.url, $0.title, $0.lastVisitedAt) }
            } else {
                entries = ((try? SuggestionProvider().suggestions(for: q, limit: 8)) ?? []).map { ($0.url, $0.title, nil) }
            }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            let shown = entries.filter { filter == .history || !favoriteURLs.contains($0.url) }.prefix(filter == .all ? 5 : 30)
            sections.append(PaletteSection(title: "Historique", items: shown.map { entry in
                PaletteItem(
                    icon: .symbol("clock"),
                    title: entry.title.isEmpty ? entry.url : entry.title,
                    subtitle: URL(string: entry.url)?.host,
                    trailing: entry.date.map { formatter.localizedString(for: $0, relativeTo: Date()) },
                    perform: { [weak self] inNewTab in self?.openFromPalette(entry.url, inNewTab: inNewTab) }
                )
            }))
        }

        if filter == .all || filter == .actions {
            let spaceItems = spaces.enumerated().filter { matches($0.element.name, "espace") && $0.offset != currentSpace }.map { index, style in
                PaletteItem(icon: .symbol(style.icon.symbol), title: "Aller à « \(style.name) »", subtitle: nil,
                            trailing: "⌃\(index + 1)", perform: { [weak self] _ in self?.selectSpace(index) })
            }
            if !spaceItems.isEmpty { sections.append(PaletteSection(title: "Espaces", items: Array(spaceItems.prefix(filter == .all && q.isEmpty ? 3 : 12)))) }
            var actions: [(String, String, @MainActor (BrowserWindowController) -> Void)] = [
                ("Écran partagé", "rectangle.split.2x1", { $0.toggleSplit() }),
                ("Ajouter à la liste de lecture", "text.book.closed", { if let tab = $0.activeTab { $0.addToReadingList(tab) } }),
                ("Afficher l'historique", "clock", { $0.openHistoryPanel() }),
                ("Gestionnaire de tâches", "gauge.with.dots.needle.33percent", { $0.showTaskManager() }),
                ("Personnaliser l'apparence", "paintbrush", { $0.openCustomize() }),
                ("Vue d'ensemble des espaces", "square.grid.2x2", { $0.openOverview() }),
                ("Mettre l'onglet en veille", "moon", { $0.sleepActiveTab() }),
                ("Nouvel onglet vide", "plus", { $0.newTab(urlString: nil, isPrivate: SettingsStore.shared.privateByDefault) }),
                ("Nouvel onglet privé", "lock.shield", { $0.newPrivateTabAction() }),
                ("Rouvrir l'onglet fermé", "arrow.uturn.backward", { $0.reopenClosedTab() }),
                ("Onglets archivés…", "archivebox", { $0.showArchiveMenu() }),
                ("Notes", "note.text", { $0.showNotes() }),
                ("Aller à l'espace suivant", "square.stack", { $0.selectNextSpace() }),
                ("Recharger la page", "arrow.clockwise", { $0.reloadAction() }),
                ("Ajouter ou retirer des favoris", "star", { if let tab = $0.activeTab { $0.toggleBookmark(for: tab) } }),
                ("Rechercher dans la page", "text.magnifyingglass", { $0.findInPage() }),
                ("Afficher ou masquer la barre latérale", "sidebar.left", { $0.toggleSidebar() }),
                ("Fermer l'onglet", "xmark", { $0.closeActiveTabAction() }),
                ("Réglages", "gearshape", { $0.openSettings() }),
            ]
            if let host = activeTab?.webView?.url?.host, activeTab?.webView?.url?.scheme?.hasPrefix("http") == true {
                let asChrome = SettingsStore.shared.chromeUserAgentHosts.contains { UserAgent.hostMatches(host, listed: $0) }
                actions.append((asChrome ? "Se présenter comme Safari sur ce site" : "Se présenter comme Chrome sur ce site", "person.crop.circle.badge.questionmark", { $0.toggleChromeAgentForCurrentSite() }))
            }
            if activeTab?.webView?.url?.scheme?.hasPrefix("http") == true {
                actions.append((activeTab?.readerOrigin == nil ? "Mode lecture" : "Quitter le mode lecture", "text.book.closed", { $0.toggleReaderMode() }))
            }
            if let host = activeTab?.webView?.url?.host, activeTab?.webView?.url?.scheme?.hasPrefix("http") == true {
                let mobile = SettingsStore.shared.mobileSiteHosts.contains { UserAgent.hostMatches(host, listed: $0) }
                actions.append((mobile ? "Demander la version ordinateur de ce site" : "Demander la version mobile de ce site", "iphone", { $0.toggleMobileForCurrentSite() }))
                actions.append(("Lire la page à voix haute", "speaker.wave.2", { $0.readPageAloud() }))
                actions.append(("Partager la page…", "square.and.arrow.up", { $0.sharePage() }))
            }
            if PageTranslator.isAvailable, TranslationPolicy.canTranslate(url: activeTab?.webView?.url) {
                let showing = activeTab?.translator.state != .idle
                actions.append((showing ? "Afficher la page d'origine" : "Traduire la page", "translate", { $0.translatePageAction() }))
            }
            if TranslationPolicy.canTranslate(url: activeTab?.webView?.url) {
                actions.append((digestPanel.state == "closed" ? "L'essentiel" : "Fermer « L'essentiel »", "list.bullet.clipboard", { $0.digestAction() }))
            }
            actions.append(("Demander à l'IA", "sparkles", { $0.askAIAction() }))
            actions.append(contentsOf: webPanelActions())
            if TranslationPolicy.canTranslate(url: activeTab?.webView?.url) {
                actions.append(("Ajouter au Calendrier", "calendar.badge.plus", { $0.addToCalendarAction() }))
                actions.append(("Personnaliser ce site…", "wand.and.stars", { $0.customizeSiteAction() }))
                let boost = try? boostRepo.boost(for: activeTab?.webView?.url?.host)
                if boost?.rules.isEmpty == false { actions.append(("Retirer les changements de ce site", "arrow.uturn.backward.circle", { $0.removeBoostAction() })) }
                actions.append((boost?.calm == true ? "Mode calme : le quitter sur ce site" : "Mode calme sur ce site", "leaf", { $0.toggleCalmForSiteAction() }))
            }
            let night = SettingsStore.shared.nightMode
            for (mode, title) in [(NightMode.always, "Mode nuit : toujours"), (.auto, "Mode nuit : automatique (suit le Mac)"), (.off, "Mode nuit : désactivé")] where mode != night {
                actions.append((title, "moon", { $0.setNightMode(mode) }))
            }
            if night != .off, TranslationPolicy.canTranslate(url: activeTab?.webView?.url) {
                actions.append(("Mode nuit : ce site clair ou sombre", "moon.circle", { $0.toggleNightForCurrentSite() }))
            }
            if PageTranslator.isAvailable, activeTab?.translator.pageLanguage.map({ $0 != "und" }) == true {
                actions.append(("Télécharger la traduction rapide", "arrow.down.circle", { $0.downloadFastTranslationAction() }))
            }
            let found = actions.filter { matches($0.0) }
            sections.append(PaletteSection(title: "Actions", items: found.prefix(filter == .all && q.isEmpty ? 4 : 12).map { action in
                PaletteItem(icon: .symbol(action.1), title: action.0, subtitle: nil, trailing: nil,
                            perform: { [weak self] _ in if let self { action.2(self) } })
            }))
        }
        return sections
    }

    /// Whether typed text should be opened as an address rather than searched.
    static func looksLikeAddress(_ text: String) -> Bool { AddressResolver.looksLikeAddress(text) }

    func buildFindBar(in contentView: NSView) {
        findField.translatesAutoresizingMaskIntoConstraints = false
        findField.placeholderString = "Rechercher dans la page"
        findField.setAccessibilityLabel("Rechercher dans la page")
        findField.isBordered = false
        findField.focusRingType = .none
        findField.target = self
        findField.action = #selector(findNext)
        findField.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let prevButton = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Précédent")!, target: self, action: #selector(findPrevious))
        let nextButton = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Suivant")!, target: self, action: #selector(findNext))
        let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Fermer")!, target: self, action: #selector(closeFindBar))
        [prevButton, nextButton, closeButton].forEach {
            $0.isBordered = false
            $0.bezelStyle = .circular
        }

        findBar.orientation = .horizontal
        findBar.spacing = 4
        findBar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        [findField, prevButton, nextButton, closeButton].forEach { findBar.addArrangedSubview($0) }

        let findCard = makeFloatingCard(findBar, cornerRadius: 10)
        findCard.isHidden = true
        self.findBarContainer = findCard

        contentView.addSubview(findCard)
        NSLayoutConstraint.activate([
            findCard.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 8),
            findCard.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -16),
        ])
    }
}
