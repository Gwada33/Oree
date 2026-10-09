import Foundation

/// How the sidebar is shown. `fixed` = 286 pt, `compact` = icons only (also forced
/// automatically in narrow windows), `floating` = overlay revealed from the left edge,
/// `hidden` = gone until toggled.
public enum SidebarMode: String, CaseIterable, Sendable, Codable {
    case fixed, compact, floating, hidden
    public var label: String {
        switch self {
        case .fixed: "Fixe"; case .compact: "Compacte"; case .floating: "Au survol"; case .hidden: "Masquée"
        }
    }
    /// Modes where the sidebar floats over the page instead of taking its own column.
    public var overlaysPage: Bool { self == .floating }
}

/// User-resizable sidebar width (drag its right edge).
public enum SidebarWidth {
    public static let minimum = 220.0
    public static let maximum = 480.0
    public static let standard = OreeTokens.Metrics.sidebarWidth
    public static func clamp(_ value: Double) -> Double { min(max(value, minimum), maximum) }
}

/// Icons a space can wear. `symbol` is the SF Symbol used to draw it.
public enum SpaceIcon: String, CaseIterable, Sendable, Codable {
    case leaf, code, plane, book, home, briefcase, heart, star
    public var symbol: String {
        switch self {
        case .leaf: "leaf"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .plane: "airplane"
        case .book: "book"
        case .home: "house"
        case .briefcase: "briefcase"
        case .heart: "heart"
        case .star: "star"
        }
    }
}

/// A named group of tabs with a hue and an icon.
public struct SpaceStyle: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var hue: OreeTokens.Hue
    public var icon: SpaceIcon

    public init(id: UUID = UUID(), name: String, hue: OreeTokens.Hue, icon: SpaceIcon) {
        self.id = id; self.name = name; self.hue = hue; self.icon = icon
    }

    /// First-run spaces.
    public static let defaults: [SpaceStyle] = [
        .init(name: "Perso", hue: .mousse, icon: .leaf),
        .init(name: "Travail", hue: .marine, icon: .code),
        .init(name: "Lecture", hue: .prune, icon: .book),
    ]
}

/// Effective sidebar mode for a window width: narrow windows fall back to compact.
public func effectiveSidebarMode(_ requested: SidebarMode, windowWidth: Double) -> SidebarMode {
    (requested == .fixed && windowWidth < OreeTokens.Metrics.narrowWindow) ? .compact : requested
}

/// Where the tabs live: in the left sidebar, or in a strip above the toolbar.
public enum TabLayout: String, CaseIterable, Sendable, Codable {
    case vertical, horizontal
    public var label: String { self == .vertical ? "Verticaux" : "En haut" }
}
