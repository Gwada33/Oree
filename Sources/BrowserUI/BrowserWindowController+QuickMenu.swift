import AppKit
import WebKit
import BrowserCore

/// Le menu des trois petits points (comme dans Chrome) : les actions de tous les jours, à portée d'un clic. ⌘K ouvre toujours la palette (toutes les commandes).
extension BrowserWindowController {
    func showQuickMenu() {
        let menu = quickMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: moreButton.bounds.maxX, y: moreButton.bounds.minY - 4), in: moreButton)
    }

    func quickMenu() -> NSMenu {
        let menu = NSMenu(title: "Menu")
        menu.autoenablesItems = false
        let tab = activeTab
        let url = tab?.currentURL
        let isWeb = url?.scheme == "http" || url?.scheme == "https"
        let isApp = webApp != nil

        func add(_ title: String, _ shortcut: String = "", symbol: String? = nil, enabled: Bool = true, _ action: @escaping @MainActor () -> Void) {
            let item = ClosureMenuItem(title: shortcut.isEmpty ? title : title, action: action)
            item.isEnabled = enabled
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
            if !shortcut.isEmpty { item.toolTip = shortcut }
            menu.addItem(item)
        }
        func submenu(_ title: String, symbol: String, _ build: (NSMenu) -> Void) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            let sub = NSMenu(title: title); sub.autoenablesItems = false; build(sub); item.submenu = sub; menu.addItem(item)
        }
        func addTo(_ sub: NSMenu, _ title: String, enabled: Bool = true, _ action: @escaping @MainActor () -> Void) {
            let item = ClosureMenuItem(title: title, action: action); item.isEnabled = enabled; sub.addItem(item)
        }

        // Ouvrir
        add("Nouvel onglet", symbol: "plus.square") { [weak self] in self?.newTabAction() }
        add("Nouvelle fenêtre", symbol: "macwindow.badge.plus") { [weak self] in self?.newWindowAction() }
        add("Nouvel onglet privé", symbol: "eye.slash") { [weak self] in self?.newPrivateTabAction() }
        menu.addItem(.separator())

        // Aller
        add("Favoris", symbol: "star") { [weak self] in self?.activePanel = .favorites; self?.refreshPanel() }
        add("Historique", symbol: "clock") { [weak self] in self?.openHistoryAction() }
        add("Téléchargements", symbol: "arrow.down.circle") { [weak self] in self?.toggleDownloads() }
        add("Rouvrir l'onglet fermé", symbol: "arrow.uturn.backward", enabled: !closedTabs.isEmpty) { [weak self] in self?.reopenClosedTab() }
        menu.addItem(.separator())

        // Cette page
        if isWeb, let tab {
            let marked = (try? bookmarkRepo.contains(url: url!.absoluteString)) ?? false
            add(marked ? "Retirer des favoris" : "Ajouter aux favoris", symbol: marked ? "star.slash" : "star.fill") { [weak self] in self?.toggleBookmark(for: tab) }
            add("Garder pour plus tard (liste de lecture)", symbol: "books.vertical") { [weak self] in self?.addToReadingList(tab) }
        }
        add("Trouver dans la page", symbol: "magnifyingglass", enabled: isWeb) { [weak self] in self?.findInPage() }
        submenu("Zoom", symbol: "plus.magnifyingglass") { sub in
            addTo(sub, "Zoom avant") { [weak self] in self?.zoomInAction() }
            addTo(sub, "Zoom arrière") { [weak self] in self?.zoomOutAction() }
            addTo(sub, "Taille réelle") { [weak self] in self?.zoomResetAction() }
        }
        submenu("Outils de la page", symbol: "wrench.and.screwdriver") { sub in
            addTo(sub, "Traduire la page", enabled: isWeb) { [weak self] in self?.translatePageAction() }
            addTo(sub, "L'essentiel (résumé)", enabled: isWeb) { [weak self] in self?.digestAction() }
            addTo(sub, "Mode lecture", enabled: isWeb) { [weak self] in self?.toggleReaderMode() }
            addTo(sub, "Mode nuit pour ce site", enabled: isWeb) { [weak self] in self?.toggleNightForCurrentSite() }
            addTo(sub, "Lire la page à voix haute", enabled: isWeb) { [weak self] in self?.readPageAloud() }
            sub.addItem(.separator())
            addTo(sub, "Imprimer…", enabled: isWeb) { [weak self] in self?.printPage() }
            addTo(sub, "Enregistrer en PDF…", enabled: isWeb) { [weak self] in self?.savePageAsPDF() }
            addTo(sub, "Code QR de la page", enabled: isWeb) { [weak self] in self?.showPageQRCode() }
            addTo(sub, "Afficher le code source", enabled: isWeb) { [weak self] in self?.viewPageSource() }
        }
        add("Partager la page…", symbol: "square.and.arrow.up", enabled: isWeb) { [weak self] in self?.sharePage() }
        if !isApp && isWeb { add("Installer ce site comme application…", symbol: "square.and.arrow.down.on.square") { [weak self] in self?.installWebAppAction() } }
        menu.addItem(.separator())

        // Orée
        add("Demander à Luciole", symbol: "sparkles") { [weak self] in self?.askAIAction() }
        let apps = webAppStore.all()
        if !apps.isEmpty { submenu("Applications", symbol: "square.grid.2x2") { sub in for app in apps { addTo(sub, app.name) { [weak self] in self?.openWebApp(app) } } } }
        add("Écran partagé", symbol: "rectangle.split.2x1", enabled: !isApp) { [weak self] in self?.toggleSplit() }
        menu.addItem(.separator())
        add("Personnaliser Orée…", symbol: "slider.horizontal.3") { [weak self] in self?.openCustomize() }
        add("Réglages…", symbol: "gearshape") { [weak self] in self?.openSettings() }
        add("Toutes les commandes…  ⌘K", symbol: "command") { [weak self] in self?.openPalette(initialText: "", selectAll: false, opensInNewTab: true) }
        return menu
    }
}
