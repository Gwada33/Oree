import AppKit
import CoreSpotlight
import BrowserCore
import BrowserStorage

/// Les petites choses d'une vraie application Mac : le menu du Dock, le menu Services (texte sélectionné dans une autre application), Spotlight.
extension BrowserWindowController {
    // MARK: Menu du Dock (clic droit sur l'icône)

    public func makeDockMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Nouvelle fenêtre") { [weak self] in self?.newWindowAction() })
        menu.addItem(ClosureMenuItem(title: "Nouvel onglet") { [weak self] in
            guard let self else { return }
            self.window?.makeKeyAndOrderFront(nil); self.journalOpenHow = "new"
            self.newTab(urlString: nil, isPrivate: SettingsStore.shared.privateByDefault)
            self.addressPill.beginEditing(text: "", selectAll: false)
        })
        menu.addItem(ClosureMenuItem(title: "Nouvel onglet privé") { [weak self] in self?.window?.makeKeyAndOrderFront(nil); self?.newPrivateTabAction() })
        let recent = tabs.filter { !$0.isPrivate && $0.currentURL != nil }.sorted { $0.lastActiveDate > $1.lastActiveDate }.prefix(8)
        if !recent.isEmpty {
            menu.addItem(.separator())
            for tab in recent {
                let title = tab.displayTitle.isEmpty ? (tab.badgeHost.isEmpty ? "Sans titre" : tab.badgeHost) : tab.displayTitle
                let item = ClosureMenuItem(title: String(title.prefix(48))) { [weak self, weak tab] in
                    guard let self, let tab else { return }
                    self.window?.makeKeyAndOrderFront(nil); self.journalSelectVia = "other"; self.selectTab(tab)
                }
                item.state = tab.id == activeTabID ? .on : .off
                menu.addItem(item)
            }
        }
        if !closedTabs.isEmpty {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Rouvrir l'onglet fermé") { [weak self] in self?.reopenClosedTab() })
        }
        return menu
    }

    // MARK: Services (texte sélectionné ailleurs › « Ouvrir ou rechercher dans Orée »)

    /// Une adresse s'ouvre ; tout autre texte est cherché avec le moteur de recherche choisi. Dans un nouvel onglet, la fenêtre passe devant.
    public func openFromService(text: String) {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.count <= 2000 else { return }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        journalOpenHow = "external"
        openFromPalette(raw, inNewTab: true)
    }

    // MARK: Spotlight

    /// À chaque changement de réglage : le réglage vient-il de changer ? Alors on construit l'index, ou on le vide.
    func spotlightSettingsChanged() {
        let on = SettingsStore.shared.spotlightIndexing
        guard on != spotlightWasEnabled else { return }
        spotlightWasEnabled = on
        on ? reindexSpotlight() : SpotlightIndexer.shared.removeAll()
    }

    /// Au lancement (si le réglage est actif) et quand il s'allume.
    public func reindexSpotlight() {
        spotlightWasEnabled = SettingsStore.shared.spotlightIndexing
        guard spotlightWasEnabled else { return }
        let bookmarks = (try? bookmarkRepo.all()) ?? []
        let history = (try? historyRepo.recent(limit: SpotlightIndexer.historyLimit)) ?? []
        SpotlightIndexer.shared.reindex(bookmarks: bookmarks, history: history)
    }

    /// Un clic sur un résultat Spotlight : la page s'ouvre dans Orée.
    public func openSpotlightResult(identifier: String) {
        guard let url = SpotlightIndexer.url(fromIdentifier: identifier) else { return }
        openExternal(url)
    }
}
