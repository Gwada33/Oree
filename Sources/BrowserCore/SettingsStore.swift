import Foundation

/// Light / dark / follow the system.
public enum AppearanceMode: String, CaseIterable, Sendable, Codable {
    case light, dark, auto
    public var label: String { switch self { case .light: "Clair"; case .dark: "Sombre"; case .auto: "Auto" } }
}

public enum SearchEngine: String, CaseIterable, Sendable {
    case google
    case duckduckgoLite

    public var displayName: String {
        switch self {
        case .google: return "Google"
        case .duckduckgoLite: return "DuckDuckGo Lite (zéro JS, le plus léger)"
        }
    }

    public var queryURL: String {
        switch self {
        case .google: return "https://www.google.com/search"
        case .duckduckgoLite: return "https://lite.duckduckgo.com/lite/"
        }
    }
}

/// App preferences, backed by `UserDefaults` (the standard, lightweight
/// mechanism for this — no need for a custom file format). Every setting
/// here actually changes app behavior; nothing decorative.
///
/// `@unchecked Sendable`: the only stored state is an immutable reference to
/// `UserDefaults`, which is itself thread-safe — there's no actual shared
/// mutable state for Swift's concurrency checker to worry about here.
public final class SettingsStore: @unchecked Sendable {
    public static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let searchEngine = "settings.searchEngine"
        static let adBlockEnabled = "settings.adBlockEnabled"
        static let autoSuspendMinutes = "settings.autoSuspendMinutes"
        static let freezeAfterSeconds = "settings.freezeAfterSeconds"
        static let neverSleepHosts = "settings.neverSleepHosts"
        static let privateByDefault = "settings.privateByDefault"
        static let customHomepageURL = "settings.customHomepageURL"
        static let autoplayMediaAllowed = "settings.autoplayMediaAllowed"
        static let httpsOnly = "settings.httpsOnly"
        static let urlCleaning = "settings.urlCleaning"
        static let fingerprintProtection = "settings.fingerprintProtection"
        static let safeBrowsingEnabled = "settings.safeBrowsingEnabled"
        static let safeBrowsingAPIKey = "settings.safeBrowsingAPIKey"
        static let webInspectorEnabled = "settings.webInspectorEnabled"
        static let startPageShowsRecent = "settings.startPageShowsRecent"
        static let instantBack = "settings.instantBack"
        static let memoryBudgetMB = "settings.memoryBudgetMB"
        static let backgroundCleanup = "settings.backgroundCleanup"
        static let lightLongPages = "settings.lightLongPages"
        static let learnSiteMemory = "settings.learnSiteMemory"
        static let appearanceMode = "settings.appearanceMode"
        static let accentHue = "settings.accentHue"
        static let density = "settings.density"
        static let cornerRadius = "settings.cornerRadius"
        static let uiTextOffset = "settings.uiTextOffset"
        static let calmMotion = "settings.calmMotion"
        static let sidebarMode = "settings.sidebarMode"
        static let onboardingDone = "settings.onboardingDone"
        static let tabLayout = "settings.tabLayout"
        static let downloadMaxConnections = "settings.downloadMaxConnections"
        static let downloadAdaptive = "settings.downloadAdaptive"
        static let downloadMirrors = "settings.downloadMirrors"
        static let downloadYield = "settings.downloadYieldToBrowsing"
        static let sidebarWidth = "settings.sidebarWidth"
        static let sidebarGlass = "settings.sidebarGlass"
        static let lookProfiles = "settings.lookProfiles"
        static let shortcutOverrides = "settings.shortcutOverrides"
        static let homeBackground = "settings.homeBackground"
        static let homePhotoPath = "settings.homePhotoPath"
        static let homeShowsFavorites = "settings.homeShowsFavorites"
        static let homeShowsSpaces = "settings.homeShowsSpaces"
    }

    private init() {
        defaults.register(defaults: [
            Key.searchEngine: SearchEngine.google.rawValue,
            Key.adBlockEnabled: true,
            Key.autoSuspendMinutes: 45,
            Key.freezeAfterSeconds: 120,
            Key.privateByDefault: false,
            Key.customHomepageURL: "",
            Key.autoplayMediaAllowed: false,
            Key.httpsOnly: true,
            Key.urlCleaning: true,
            Key.fingerprintProtection: true,
            // Opt-in: Safe Browsing sends hash prefixes of visited URLs to Google.
            Key.safeBrowsingEnabled: false,
            Key.safeBrowsingAPIKey: "",
            Key.webInspectorEnabled: false,
            Key.startPageShowsRecent: true,
            // Keeping previous pages alive makes "Back" instant but costs real memory
            // (measured: ~35 % more after browsing through 6 sites in one tab). Default it
            // on only where there is room: more than 8 GB of RAM.
            Key.instantBack: ProcessInfo.processInfo.physicalMemory > 9_000_000_000,
            Key.memoryBudgetMB: 0,   // 0 = automatic (a quarter of RAM)
            // Off by default until its effect on the active tab's smoothness has been measured.
            Key.backgroundCleanup: false,
            Key.lightLongPages: false,
            Key.learnSiteMemory: true,
            Key.appearanceMode: AppearanceMode.auto.rawValue,
            Key.accentHue: OreeTokens.Hue.mousse.rawValue,
            Key.density: OreeTokens.Density.standard.rawValue,
            Key.cornerRadius: OreeTokens.defaultRadius,
            Key.uiTextOffset: 0,
            Key.calmMotion: false,
            Key.sidebarMode: SidebarMode.fixed.rawValue,
            Key.onboardingDone: false,
            Key.tabLayout: TabLayout.vertical.rawValue,
            Key.downloadMaxConnections: 8,
            Key.downloadAdaptive: true,
            Key.downloadMirrors: true,
            Key.downloadYield: true,
            Key.sidebarWidth: SidebarWidth.standard,
            Key.sidebarGlass: true,
            Key.homeBackground: HomeBackground.uni.rawValue,
            Key.homePhotoPath: "",
            Key.homeShowsFavorites: true,
            Key.homeShowsSpaces: true,
        ])
    }

    public var searchEngine: SearchEngine {
        get { SearchEngine(rawValue: defaults.string(forKey: Key.searchEngine) ?? "") ?? .google }
        set { defaults.set(newValue.rawValue, forKey: Key.searchEngine) }
    }

    public var adBlockEnabled: Bool {
        get { defaults.bool(forKey: Key.adBlockEnabled) }
        set { defaults.set(newValue, forKey: Key.adBlockEnabled) }
    }

    /// Minutes of inactivity before a background tab is discarded to free RAM.
    public var autoSuspendMinutes: Int {
        get { defaults.integer(forKey: Key.autoSuspendMinutes) }
        set { defaults.set(newValue, forKey: Key.autoSuspendMinutes) }
    }

    /// Seconds a tab stays hidden before it is frozen (page alive but paused). 0 = never freeze.
    public var freezeAfterSeconds: Int {
        get { defaults.integer(forKey: Key.freezeAfterSeconds) }
        set { defaults.set(newValue, forKey: Key.freezeAfterSeconds) }
    }

    /// Sites the user asked never to freeze or sleep.
    public var neverSleepHosts: [String] {
        get { defaults.stringArray(forKey: Key.neverSleepHosts) ?? [] }
        set { defaults.set(newValue, forKey: Key.neverSleepHosts) }
    }

    public var privateByDefault: Bool {
        get { defaults.bool(forKey: Key.privateByDefault) }
        set { defaults.set(newValue, forKey: Key.privateByDefault) }
    }

    /// Empty string means "use the built-in local start page".
    public var customHomepageURL: String {
        get { defaults.string(forKey: Key.customHomepageURL) ?? "" }
        set { defaults.set(newValue, forKey: Key.customHomepageURL) }
    }

    public var autoplayMediaAllowed: Bool {
        get { defaults.bool(forKey: Key.autoplayMediaAllowed) }
        set { defaults.set(newValue, forKey: Key.autoplayMediaAllowed) }
    }

    public var httpsOnly: Bool {
        get { defaults.bool(forKey: Key.httpsOnly) }
        set { defaults.set(newValue, forKey: Key.httpsOnly) }
    }

    public var urlCleaning: Bool {
        get { defaults.bool(forKey: Key.urlCleaning) }
        set { defaults.set(newValue, forKey: Key.urlCleaning) }
    }

    public var fingerprintProtection: Bool {
        get { defaults.bool(forKey: Key.fingerprintProtection) }
        set { defaults.set(newValue, forKey: Key.fingerprintProtection) }
    }

    /// Off by default: enabling it means hash prefixes of visited URLs are sent to Google.
    public var safeBrowsingEnabled: Bool {
        get { defaults.bool(forKey: Key.safeBrowsingEnabled) }
        set { defaults.set(newValue, forKey: Key.safeBrowsingEnabled) }
    }

    public var safeBrowsingAPIKey: String {
        get { defaults.string(forKey: Key.safeBrowsingAPIKey) ?? "" }
        set { defaults.set(newValue, forKey: Key.safeBrowsingAPIKey) }
    }

    /// Lets Safari's Web Inspector attach to pages (right-click > Inspect Element).
    public var webInspectorEnabled: Bool {
        get { defaults.bool(forKey: Key.webInspectorEnabled) }
        set { defaults.set(newValue, forKey: Key.webInspectorEnabled) }
    }

    /// Whether the new-tab page lists recently visited sites (anyone glancing at the screen sees it).
    public var startPageShowsRecent: Bool {
        get { defaults.bool(forKey: Key.startPageShowsRecent) }
        set { defaults.set(newValue, forKey: Key.startPageShowsRecent) }
    }

    /// Keep recently left pages in memory (WebKit's back-forward cache). Read once at launch.
    public var instantBack: Bool {
        get { defaults.bool(forKey: Key.instantBack) }
        set { defaults.set(newValue, forKey: Key.instantBack) }
    }

    /// Memory the open tabs may use before the heaviest hidden ones are put to sleep.
    /// 0 = automatic (a quarter of the machine's RAM), -1 = no limit, otherwise megabytes.
    public var memoryBudgetMB: Int {
        get { defaults.integer(forKey: Key.memoryBudgetMB) }
        set { defaults.set(newValue, forKey: Key.memoryBudgetMB) }
    }

    /// Periodically run a JavaScript garbage collection once tabs have been hidden for a while.
    public var backgroundCleanup: Bool {
        get { defaults.bool(forKey: Key.backgroundCleanup) }
        set { defaults.set(newValue, forKey: Key.backgroundCleanup) }
    }

    /// Experimental: skip layout/paint of far-off-screen blocks on very long pages.
    public var lightLongPages: Bool {
        get { defaults.bool(forKey: Key.lightLongPages) }
        set { defaults.set(newValue, forKey: Key.lightLongPages) }
    }

    /// Remember (locally) how much memory each site tends to use, and use it to make room in advance.
    public var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.string(forKey: Key.appearanceMode) ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: Key.appearanceMode) }
    }

    /// Accent hue for focus rings, buttons and the default space color.
    public var accentHue: OreeTokens.Hue {
        get { OreeTokens.Hue(rawValue: defaults.string(forKey: Key.accentHue) ?? "") ?? .mousse }
        set { defaults.set(newValue.rawValue, forKey: Key.accentHue) }
    }

    public var density: OreeTokens.Density {
        get { OreeTokens.Density(rawValue: defaults.string(forKey: Key.density) ?? "") ?? .standard }
        set { defaults.set(newValue.rawValue, forKey: Key.density) }
    }

    /// Base corner radius, 0...16.
    public var cornerRadius: Double {
        get { min(max(defaults.double(forKey: Key.cornerRadius), 0), 16) }
        set { defaults.set(min(max(newValue, 0), 16), forKey: Key.cornerRadius) }
    }

    /// Interface text size delta in points (-1, 0, +1). Does not affect page zoom.
    public var uiTextOffset: Int {
        get { min(max(defaults.integer(forKey: Key.uiTextOffset), -1), 1) }
        set { defaults.set(min(max(newValue, -1), 1), forKey: Key.uiTextOffset) }
    }

    /// Replace movement by plain fades (also honoured when macOS asks to reduce motion).
    public var calmMotion: Bool {
        get { defaults.bool(forKey: Key.calmMotion) }
        set { defaults.set(newValue, forKey: Key.calmMotion) }
    }

    public var sidebarMode: SidebarMode {
        get {
            let raw = defaults.string(forKey: Key.sidebarMode) ?? ""
            return SidebarMode(rawValue: raw == "overlay" ? "floating" : raw) ?? .fixed   // "Superposée" was folded into "Au survol"
        }
        set { defaults.set(newValue.rawValue, forKey: Key.sidebarMode) }
    }

    /// User-chosen shortcuts by command id (see `ShortcutRegistry`); missing = default.
    public var shortcutOverrides: [String: KeyBinding] {
        get {
            defaults.data(forKey: Key.shortcutOverrides).flatMap { try? JSONDecoder().decode([String: KeyBinding].self, from: $0) } ?? [:]
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.shortcutOverrides) }
    }

    /// Width of the expanded sidebar in points (220...480).
    public var sidebarWidth: Double {
        get { SidebarWidth.clamp(defaults.double(forKey: Key.sidebarWidth)) }
        set { defaults.set(SidebarWidth.clamp(newValue), forKey: Key.sidebarWidth) }
    }

    /// Liquid Glass (translucent) sidebar when it floats over the page; solid otherwise.
    public var sidebarGlass: Bool {
        get { defaults.bool(forKey: Key.sidebarGlass) }
        set { defaults.set(newValue, forKey: Key.sidebarGlass) }
    }

    /// Upper bound of parallel connections per download (1…16).
    public var downloadMaxConnections: Int {
        get { min(max(defaults.integer(forKey: Key.downloadMaxConnections), 1), 16) }
        set { defaults.set(min(max(newValue, 1), 16), forKey: Key.downloadMaxConnections) }
    }
    /// Start with a few connections and add more while each one brings ≥ 10 % more speed.
    public var downloadAdaptive: Bool {
        get { defaults.bool(forKey: Key.downloadAdaptive) }
        set { defaults.set(newValue, forKey: Key.downloadAdaptive) }
    }
    /// Race the origin against mirrors the server announces (Link rel=duplicate, Metalink).
    public var downloadMirrors: Bool {
        get { defaults.bool(forKey: Key.downloadMirrors) }
        set { defaults.set(newValue, forKey: Key.downloadMirrors) }
    }
    /// Slow downloads down while a page is loading, so browsing stays snappy.
    public var downloadYieldToBrowsing: Bool {
        get { defaults.bool(forKey: Key.downloadYield) }
        set { defaults.set(newValue, forKey: Key.downloadYield) }
    }

    public var tabLayout: TabLayout {
        get { TabLayout(rawValue: defaults.string(forKey: Key.tabLayout) ?? "") ?? .vertical }
        set { defaults.set(newValue.rawValue, forKey: Key.tabLayout) }
    }

    /// Configurations saved by the user (the built-in ones live in `LookProfile.builtIn`).
    public var savedLookProfiles: [LookProfile] {
        get { defaults.data(forKey: Key.lookProfiles).flatMap { try? JSONDecoder().decode([LookProfile].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.lookProfiles) }
    }

    /// Whether the 3-step welcome has been completed or skipped.
    public var onboardingDone: Bool {
        get { defaults.bool(forKey: Key.onboardingDone) }
        set { defaults.set(newValue, forKey: Key.onboardingDone) }
    }

    public var homeBackground: HomeBackground {
        get { HomeBackground(rawValue: defaults.string(forKey: Key.homeBackground) ?? "") ?? .uni }
        set { defaults.set(newValue.rawValue, forKey: Key.homeBackground) }
    }

    /// Image file used when the background is `.photo`.
    public var homePhotoPath: String {
        get { defaults.string(forKey: Key.homePhotoPath) ?? "" }
        set { defaults.set(newValue, forKey: Key.homePhotoPath) }
    }

    public var homeShowsFavorites: Bool {
        get { defaults.bool(forKey: Key.homeShowsFavorites) }
        set { defaults.set(newValue, forKey: Key.homeShowsFavorites) }
    }

    public var homeShowsSpaces: Bool {
        get { defaults.bool(forKey: Key.homeShowsSpaces) }
        set { defaults.set(newValue, forKey: Key.homeShowsSpaces) }
    }

    public var learnSiteMemory: Bool {
        get { defaults.bool(forKey: Key.learnSiteMemory) }
        set { defaults.set(newValue, forKey: Key.learnSiteMemory) }
    }
}
