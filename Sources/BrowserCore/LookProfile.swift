import Foundation

/// A saved "configuration": every look-and-feel choice in one value, so a whole ambiance
/// (Journée, Soir, Présentation, or your own) can be applied in one tap.
public struct LookProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var appearance: AppearanceMode
    public var accent: OreeTokens.Hue
    public var density: OreeTokens.Density
    public var radius: Double
    public var sidebar: SidebarMode
    public var tabLayout: TabLayout
    public var background: HomeBackground
    public var textOffset: Int
    public var calm: Bool

    public init(name: String, appearance: AppearanceMode, accent: OreeTokens.Hue, density: OreeTokens.Density, radius: Double,
                sidebar: SidebarMode, tabLayout: TabLayout, background: HomeBackground, textOffset: Int, calm: Bool) {
        self.name = name; self.appearance = appearance; self.accent = accent; self.density = density; self.radius = radius
        self.sidebar = sidebar; self.tabLayout = tabLayout; self.background = background; self.textOffset = textOffset; self.calm = calm
    }

    public static let builtIn: [LookProfile] = [
        LookProfile(name: "Journée", appearance: .light, accent: .mousse, density: .standard, radius: 10, sidebar: .fixed, tabLayout: .vertical, background: .papier, textOffset: 0, calm: false),
        LookProfile(name: "Soir", appearance: .dark, accent: .ocre, density: .standard, radius: 10, sidebar: .fixed, tabLayout: .vertical, background: .uni, textOffset: 0, calm: true),
        LookProfile(name: "Présentation", appearance: .light, accent: .marine, density: .aeree, radius: 14, sidebar: .hidden, tabLayout: .vertical, background: .uni, textOffset: 1, calm: true),
    ]

    @MainActor
    public static func capture(named name: String, from store: SettingsStore) -> LookProfile {
        LookProfile(name: name, appearance: store.appearanceMode, accent: store.accentHue, density: store.density, radius: store.cornerRadius,
                    sidebar: store.sidebarMode, tabLayout: store.tabLayout, background: store.homeBackground,
                    textOffset: store.uiTextOffset, calm: store.calmMotion)
    }

    @MainActor
    public func apply(to store: SettingsStore) {
        store.appearanceMode = appearance; store.accentHue = accent; store.density = density; store.cornerRadius = radius
        store.sidebarMode = sidebar; store.tabLayout = tabLayout; store.homeBackground = background
        store.uiTextOffset = textOffset; store.calmMotion = calm
    }

    /// Same look, ignoring the name.
    public func sameLook(as other: LookProfile) -> Bool {
        var copy = other; copy.name = name
        return copy == self
    }
}
