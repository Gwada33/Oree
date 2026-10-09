import AppKit
import BrowserCore

public final class MenuBuilder {
    weak var target: BrowserWindowController?
    private var historyMenu: NSMenu?
    private var bookmarksMenu: NSMenu?

    public init(target: BrowserWindowController) {
        self.target = target
    }

    public func build() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "À propos d’Orée", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        addCommand("customize", to: appMenu, title: "Personnaliser…", selector: #selector(BrowserWindowController.openCustomize))
        addCommand("settings", to: appMenu, title: "Réglages…", selector: #selector(BrowserWindowController.openSettings))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quitter Orée", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "Fichier")
        addCommand("newTab", to: fileMenu, selector: #selector(BrowserWindowController.newTabAction))
        addCommand("newPrivateTab", to: fileMenu, selector: #selector(BrowserWindowController.newPrivateTabAction))
        addCommand("closeTab", to: fileMenu, selector: #selector(BrowserWindowController.closeActiveTabAction))
        addCommand("reopenTab", to: fileMenu, selector: #selector(BrowserWindowController.reopenClosedTab))
        for number in 1...9 {
            let item = NSMenuItem(title: "Espace \(number)", action: #selector(BrowserWindowController.selectSpaceByNumber(_:)), keyEquivalent: String(number))
            item.keyEquivalentModifierMask = [.control]
            item.tag = number
            item.target = target
            fileMenu.addItem(item)
        }
        for number in 1...9 {
            let item = NSMenuItem(title: number == 9 ? "Dernier onglet" : "Onglet \(number)", action: #selector(BrowserWindowController.selectTabByNumber(_:)), keyEquivalent: String(number))
            item.keyEquivalentModifierMask = [.command]
            item.tag = number
            item.target = target
            fileMenu.addItem(item)
        }
        fileMenu.addItem(.separator())
        addCommand("moveTabUp", to: fileMenu, selector: #selector(BrowserWindowController.moveActiveTabUp))
        addCommand("moveTabDown", to: fileMenu, selector: #selector(BrowserWindowController.moveActiveTabDown))
        fileMenu.addItem(.separator())
        addCommand("overview", to: fileMenu, selector: #selector(BrowserWindowController.openOverview))
        addCommand("split", to: fileMenu, selector: #selector(BrowserWindowController.toggleSplit))
        addCommand("theme", to: fileMenu, selector: #selector(BrowserWindowController.cycleTheme))
        addCommand("sleepTab", to: fileMenu, selector: #selector(BrowserWindowController.sleepActiveTab))
        addCommand("palette", to: fileMenu, selector: #selector(BrowserWindowController.openPaletteAction))
        addCommand("address", to: fileMenu, selector: #selector(BrowserWindowController.focusAddressBar))
        addCommand("sidebar", to: fileMenu, selector: #selector(BrowserWindowController.toggleSidebar))
        fileMenu.addItem(.separator())
        addResponderItem(to: fileMenu, title: "Plein écran", selector: #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.command, .control])
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Édition")
        addResponderItem(to: editMenu, title: "Annuler", selector: Selector(("undo:")), key: "z")
        addResponderItem(to: editMenu, title: "Rétablir", selector: Selector(("redo:")), key: "z", modifiers: [.command, .shift])
        editMenu.addItem(.separator())
        addResponderItem(to: editMenu, title: "Couper", selector: #selector(NSText.cut(_:)), key: "x")
        addResponderItem(to: editMenu, title: "Copier", selector: #selector(NSText.copy(_:)), key: "c")
        addResponderItem(to: editMenu, title: "Coller", selector: #selector(NSText.paste(_:)), key: "v")
        addResponderItem(to: editMenu, title: "Tout sélectionner", selector: #selector(NSText.selectAll(_:)), key: "a")
        editMenu.addItem(.separator())
        addCommand("find", to: editMenu, selector: #selector(BrowserWindowController.findInPage))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let historyMenuItem = NSMenuItem()
        let historyMenu = NSMenu(title: "Historique")
        addCommand("back", to: historyMenu, title: "Précédent", selector: #selector(BrowserWindowController.goBack))
        addCommand("forward", to: historyMenu, title: "Suivant", selector: #selector(BrowserWindowController.goForward))
        addCommand("reload", to: historyMenu, selector: #selector(BrowserWindowController.reloadAction))
        addCommand("history", to: historyMenu, title: "Rechercher dans l'historique", selector: #selector(BrowserWindowController.openHistoryAction))
        historyMenu.addItem(.separator())
        self.historyMenu = historyMenu
        historyMenuItem.submenu = historyMenu
        mainMenu.addItem(historyMenuItem)
        refreshHistoryMenu()

        let bookmarksMenuItem = NSMenuItem()
        let bookmarksMenu = NSMenu(title: "Favoris")
        addCommand("bookmark", to: bookmarksMenu, selector: #selector(BrowserWindowController.addBookmark))
        bookmarksMenu.addItem(.separator())
        self.bookmarksMenu = bookmarksMenu
        bookmarksMenuItem.submenu = bookmarksMenu
        mainMenu.addItem(bookmarksMenuItem)
        refreshBookmarksMenu()

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Fenêtre")
        addResponderItem(to: windowMenu, title: "Réduire", selector: #selector(NSWindow.performMiniaturize(_:)), key: "m")
        addResponderItem(to: windowMenu, title: "Fermer la fenêtre", selector: #selector(NSWindow.performClose(_:)), key: "w", modifiers: [.command, .shift])
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    /// Rebuilds the whole menu bar after the user edited a shortcut.
    public func rebuild() {
        bindings = ShortcutRegistry.resolve(overrides: SettingsStore.shared.shortcutOverrides)
        NSApp.mainMenu = build()
    }

    private lazy var bindings = ShortcutRegistry.resolve(overrides: SettingsStore.shared.shortcutOverrides)

    private static func flags(_ m: ShortcutModifiers) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if m.contains(.command) { f.insert(.command) }
        if m.contains(.shift) { f.insert(.shift) }
        if m.contains(.option) { f.insert(.option) }
        if m.contains(.control) { f.insert(.control) }
        return f
    }

    /// A menu item whose shortcut comes from the (user-editable) registry.
    private func addCommand(_ id: String, to menu: NSMenu, title: String? = nil, selector: Selector) {
        let command = ShortcutRegistry.commands.first { $0.id == id }
        let binding = bindings[id]
        let item = NSMenuItem(title: title ?? command?.title ?? id, action: selector, keyEquivalent: binding?.key ?? "")
        if let binding { item.keyEquivalentModifierMask = Self.flags(binding.modifiers) }
        item.target = target
        menu.addItem(item)
    }

    private func addControllerItem(to menu: NSMenu, title: String, selector: Selector, key: String, modifiers: NSEvent.ModifierFlags = [.command]) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        menu.addItem(item)
    }

    private func addResponderItem(to menu: NSMenu, title: String, selector: Selector, key: String, modifiers: NSEvent.ModifierFlags = [.command]) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
    }

    func refreshHistoryMenu() {
        guard let historyMenu else { return }
        while historyMenu.items.count > 5 {
            historyMenu.removeItem(at: historyMenu.items.count - 1)
        }
        // Already ordered most-recent-first by the repository.
        let recent = target?.recentHistoryForMenu(limit: 15) ?? []
        for entry in recent {
            let item = NSMenuItem(title: entry.title.isEmpty ? entry.url : entry.title, action: #selector(BrowserWindowController.historyItemClicked(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = entry.url
            historyMenu.addItem(item)
        }
    }

    func refreshBookmarksMenu() {
        guard let bookmarksMenu else { return }
        while bookmarksMenu.items.count > 2 {
            bookmarksMenu.removeItem(at: bookmarksMenu.items.count - 1)
        }
        for bookmark in target?.allBookmarksForMenu() ?? [] {
            let item = NSMenuItem(title: bookmark.title.isEmpty ? bookmark.url : bookmark.title, action: #selector(BrowserWindowController.bookmarkItemClicked(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = bookmark.url
            bookmarksMenu.addItem(item)
        }
    }
}
