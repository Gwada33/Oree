import Foundation

/// Modifier keys of a shortcut (kept independent of AppKit so the rules can be unit tested).
public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let shift = ShortcutModifiers(rawValue: 1 << 1)
    public static let option = ShortcutModifiers(rawValue: 1 << 2)
    public static let control = ShortcutModifiers(rawValue: 1 << 3)
}

/// A key plus modifiers. `key` is the character a menu item uses ("t", "\\", or a function-key
/// scalar such as the arrow keys).
public struct KeyBinding: Codable, Hashable, Sendable {
    public var key: String
    public var modifiers: ShortcutModifiers
    public init(_ key: String, _ modifiers: ShortcutModifiers) { self.key = key; self.modifiers = modifiers }

    public static let upArrow = String(UnicodeScalar(0xF700)!)
    public static let downArrow = String(UnicodeScalar(0xF701)!)

    /// "⇧⌘L" style text, in the order macOS uses (⌃⌥⇧⌘ then the key).
    public var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case Self.upArrow: text += "↑"
        case Self.downArrow: text += "↓"
        case "\r": text += "↩"
        case " ": text += "Espace"
        default: text += key.uppercased()
        }
        return text
    }

    /// A shortcut needs a modifier other than shift alone (otherwise it would steal typing).
    public var isUsable: Bool {
        !key.isEmpty && !modifiers.subtracting(.shift).isEmpty
    }
}

public struct ShortcutCommand: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let section: String
    public let defaultBinding: KeyBinding?
}

/// Every command that has an editable shortcut, with its default.
public enum ShortcutRegistry {
    private static func c(_ id: String, _ title: String, _ section: String, _ key: String?, _ mods: ShortcutModifiers = [.command]) -> ShortcutCommand {
        ShortcutCommand(id: id, title: title, section: section, defaultBinding: key.map { KeyBinding($0, mods) })
    }

    public static let commands: [ShortcutCommand] = [
        c("newTab", "Nouvel onglet", "Onglets", "t"),
        c("newPrivateTab", "Nouvel onglet privé", "Onglets", "n", [.command, .shift]),
        c("closeTab", "Fermer l’onglet", "Onglets", "w"),
        c("reopenTab", "Rouvrir l’onglet fermé", "Onglets", "t", [.command, .shift]),
        c("sleepTab", "Mettre l’onglet en veille", "Onglets", "e", [.command, .option]),
        c("moveTabUp", "Déplacer l’onglet vers le haut", "Onglets", KeyBinding.upArrow, [.command, .shift]),
        c("moveTabDown", "Déplacer l’onglet vers le bas", "Onglets", KeyBinding.downArrow, [.command, .shift]),
        c("palette", "Palette de commandes", "Navigation", "k"),
        c("address", "Adresse", "Navigation", "l"),
        c("back", "Page précédente", "Navigation", "["),
        c("forward", "Page suivante", "Navigation", "]"),
        c("reload", "Recharger", "Navigation", "r"),
        c("find", "Rechercher dans la page", "Navigation", "f"),
        c("history", "Historique", "Navigation", "y"),
        c("bookmark", "Ajouter aux favoris", "Navigation", "d"),
        c("split", "Écran partagé", "Fenêtre", "\\"),
        c("sidebar", "Afficher ou masquer la barre latérale", "Fenêtre", "s", [.command, .option]),
        c("overview", "Vue d’ensemble des espaces", "Fenêtre", KeyBinding.upArrow, [.control]),
        c("theme", "Changer de thème", "Fenêtre", "l", [.command, .shift]),
        c("customize", "Personnaliser", "Fenêtre", ","),
        c("settings", "Réglages", "Fenêtre", ",", [.command, .shift]),
    ]

    /// Effective binding of every command: user override if present, else the default.
    /// An override with an empty key means "no shortcut".
    public static func resolve(overrides: [String: KeyBinding]) -> [String: KeyBinding] {
        var result: [String: KeyBinding] = [:]
        for command in commands {
            if let custom = overrides[command.id] {
                if !custom.key.isEmpty { result[command.id] = custom }
            } else if let binding = command.defaultBinding {
                result[command.id] = binding
            }
        }
        return result
    }

    /// The command already using `binding` (other than `id`), if any.
    public static func conflict(for binding: KeyBinding, excluding id: String, in resolved: [String: KeyBinding]) -> ShortcutCommand? {
        guard let other = resolved.first(where: { $0.key != id && $0.value == binding })?.key else { return nil }
        return commands.first { $0.id == other }
    }

    /// Shortcuts that menus use and that can't be edited (⌘1–⌘9 tabs, ⌃1–⌃9 spaces, ⌘Q, ⌘C…).
    public static func isReserved(_ binding: KeyBinding) -> Bool {
        if binding.modifiers == [.command], ["q", "c", "v", "x", "z", "a", "m", "h"].contains(binding.key.lowercased()) { return true }
        if binding.modifiers == [.command] || binding.modifiers == [.control], binding.key.count == 1, "123456789".contains(binding.key) { return true }
        return false
    }
}
