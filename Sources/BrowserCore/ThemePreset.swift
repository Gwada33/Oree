import Foundation

/// A named bundle of look-and-feel settings, applied in one tap from the customization drawer.
public struct ThemePreset: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let summary: String
    public let appearance: AppearanceMode
    public let accent: OreeTokens.Hue
    public let density: OreeTokens.Density
    public let radius: Double
    public let sidebar: SidebarMode
    public let background: HomeBackground

    public static let all: [ThemePreset] = [
        .init(name: "Orée", summary: "Équilibré, suit le système", appearance: .auto, accent: .mousse, density: .standard, radius: 10, sidebar: .fixed, background: .uni),
        .init(name: "Classique", summary: "Clair, aéré, angles nets", appearance: .light, accent: .marine, density: .aeree, radius: 6, sidebar: .fixed, background: .uni),
        .init(name: "Lecture", summary: "Papier chaud, barre discrète", appearance: .light, accent: .ocre, density: .aeree, radius: 14, sidebar: .compact, background: .papier),
        .init(name: "Atelier", summary: "Sombre, dense", appearance: .dark, accent: .brique, density: .compacte, radius: 4, sidebar: .fixed, background: .uni),
        .init(name: "Pilote", summary: "Sombre, minimal, icônes seules", appearance: .dark, accent: .graphite, density: .compacte, radius: 2, sidebar: .compact, background: .uni),
    ]

    /// Writes every field to the store.
    public func apply(to store: SettingsStore) {
        store.appearanceMode = appearance
        store.accentHue = accent
        store.density = density
        store.cornerRadius = radius
        store.sidebarMode = sidebar
        store.homeBackground = background
    }

    /// Does the store currently match this preset exactly?
    public func matches(_ store: SettingsStore) -> Bool {
        store.appearanceMode == appearance && store.accentHue == accent && store.density == density
            && store.cornerRadius == radius && store.sidebarMode == sidebar && store.homeBackground == background
    }
}
