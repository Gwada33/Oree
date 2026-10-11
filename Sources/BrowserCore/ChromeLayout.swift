import Foundation

/// Les boutons que la personne peut placer où elle veut : la barre d'outils (gauche ou droite), le bas de la barre latérale, ou nulle part.
public enum ChromeItem: String, CaseIterable, Codable, Sendable {
    case sidebarToggle, back, forward, reload
    case assistant, calendar, essentiel, night, translate, split, customize, downloads, more
    case favorites, history, downloadsPanel, reading

    public var title: String {
        switch self {
        case .sidebarToggle: "Afficher la barre latérale"
        case .back: "Page précédente"
        case .forward: "Page suivante"
        case .reload: "Recharger"
        case .assistant: "Assistant (Luciole)"
        case .calendar: "Ajouter au Calendrier"
        case .essentiel: "L'essentiel"
        case .night: "Mode nuit"
        case .translate: "Traduire la page"
        case .split: "Écran partagé"
        case .customize: "Personnaliser"
        case .downloads: "Téléchargements (barre d'outils)"
        case .more: "Palette de commandes"
        case .favorites: "Favoris"
        case .history: "Historique"
        case .downloadsPanel: "Téléchargements (liste)"
        case .reading: "Liste de lecture"
        }
    }

    /// Le pictogramme SF Symbols du bouton (le même dans la barre et dans les réglages).
    public var symbol: String {
        switch self {
        case .sidebarToggle: "sidebar.left"
        case .back: "chevron.left"
        case .forward: "chevron.right"
        case .reload: "arrow.clockwise"
        case .assistant: "sparkles"
        case .calendar: "calendar.badge.plus"
        case .essentiel: "list.bullet.clipboard"
        case .night: "moon"
        case .translate: "translate"
        case .split: "rectangle.split.2x1"
        case .customize: "paintbrush"
        case .downloads, .downloadsPanel: "arrow.down.to.line"
        case .more: "ellipsis"
        case .favorites: "star"
        case .history: "clock"
        case .reading: "text.book.closed"
        }
    }

    /// Un bouton « selon la page » : il n'a de sens que dans certains cas (une recette, une page à traduire, un téléchargement en cours…).
    public var isContextual: Bool {
        switch self {
        case .sidebarToggle, .calendar, .essentiel, .night, .translate, .downloads: true
        default: false
        }
    }

    /// La palette de commandes ne peut pas être cachée : c'est le chemin de secours vers tous les réglages.
    public var isRequired: Bool { self == .more }
}

public enum ChromeZone: String, CaseIterable, Codable, Sendable {
    case toolbarLeading, toolbarTrailing, sidebarFooter, hidden

    public var title: String {
        switch self {
        case .toolbarLeading: "Barre d'outils, à gauche"
        case .toolbarTrailing: "Barre d'outils, à droite"
        case .sidebarFooter: "Bas de la barre latérale"
        case .hidden: "Masqués"
        }
    }
}

public enum ChromeIconSize: String, CaseIterable, Codable, Sendable {
    case small, regular, large
    public var title: String { switch self { case .small: "Petites"; case .regular: "Moyennes"; case .large: "Grandes" } }
    /// Côté du bouton et taille du pictogramme, en points (28 / 14 = réglage d'origine de la barre d'outils).
    public var button: Double { switch self { case .small: 24; case .regular: 28; case .large: 34 } }
    public var glyph: Double { switch self { case .small: 12; case .regular: 14; case .large: 17 } }
}

/// La disposition des boutons de la barre d'outils et de la barre latérale. Pure et sérialisable : l'interface l'applique, les réglages la changent.
///
/// Règle d'or : tout bouton est quelque part exactement une fois (`normalized`), et la palette de commandes ne disparaît jamais.
public struct ChromeLayout: Codable, Equatable, Sendable {
    public var zones: [ChromeZone: [ChromeItem]]
    /// Boutons « selon la page » gardés toujours à leur place, grisés quand ils ne servent pas : rien ne bouge quand on change de page.
    public var pinned: Set<ChromeItem>
    public var iconSize: ChromeIconSize
    public var showSearchRow: Bool
    public var showNewTabRow: Bool

    public static let standard = ChromeLayout(
        zones: [
            .toolbarLeading: [.sidebarToggle, .back, .forward, .reload],
            .toolbarTrailing: [.calendar, .essentiel, .night, .translate, .split, .assistant, .customize, .downloads, .more],
            .sidebarFooter: [.favorites, .history, .downloadsPanel, .reading],
            .hidden: [],
        ],
        pinned: [], iconSize: .regular, showSearchRow: true, showNewTabRow: true)

    public init(zones: [ChromeZone: [ChromeItem]], pinned: Set<ChromeItem>, iconSize: ChromeIconSize, showSearchRow: Bool, showNewTabRow: Bool) {
        self.zones = zones; self.pinned = pinned; self.iconSize = iconSize; self.showSearchRow = showSearchRow; self.showNewTabRow = showNewTabRow
    }

    public func items(in zone: ChromeZone) -> [ChromeItem] { zones[zone] ?? [] }

    public func zone(of item: ChromeItem) -> ChromeZone {
        ChromeZone.allCases.first { items(in: $0).contains(item) } ?? .hidden
    }

    /// Place un bouton dans une zone, à une position (à la fin si `index` est nil). Un bouton obligatoire ne va pas dans « Masqués ».
    public mutating func move(_ item: ChromeItem, to zone: ChromeZone, at index: Int? = nil) {
        guard !(item.isRequired && zone == .hidden) else { return }
        for z in ChromeZone.allCases { zones[z]?.removeAll { $0 == item } }
        var list = zones[zone] ?? []
        list.insert(item, at: min(max(index ?? list.count, 0), list.count))
        zones[zone] = list
    }

    /// Chaque bouton exactement une fois ; ceux qui manquent (version plus récente de l'app) reprennent leur place d'origine ; la palette reste visible.
    public func normalized() -> ChromeLayout {
        var result = self
        var seen = Set<ChromeItem>()
        for zone in ChromeZone.allCases {
            result.zones[zone] = (zones[zone] ?? []).filter { seen.insert($0).inserted }
        }
        for item in ChromeItem.allCases where !seen.contains(item) {
            result.zones[Self.standard.zone(of: item), default: []].append(item)
        }
        if result.zone(of: .more) == .hidden { result.move(.more, to: .toolbarTrailing) }
        result.pinned = pinned.filter(\.isContextual)
        return result
    }

    public var json: String? { try? String(decoding: JSONEncoder().encode(self), as: UTF8.self) }
    public static func decode(_ json: String?) -> ChromeLayout {
        guard let json, let data = json.data(using: .utf8), let layout = try? JSONDecoder().decode(ChromeLayout.self, from: data) else { return .standard }
        return layout.normalized()
    }

    /// Les boutons à montrer dans une zone, dans l'ordre : `relevant` dit si un bouton « selon la page » sert en ce moment.
    public func visibleItems(in zone: ChromeZone, relevant: (ChromeItem) -> Bool) -> [ChromeItem] {
        items(in: zone).filter { !$0.isContextual || relevant($0) || pinned.contains($0) }
    }
}
