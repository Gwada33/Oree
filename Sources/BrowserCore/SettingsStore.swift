import Foundation

/// Light / dark / follow the system.
public enum AppearanceMode: String, CaseIterable, Sendable, Codable {
    case light, dark, auto
    public var label: String { switch self { case .light: "Clair"; case .dark: "Sombre"; case .auto: "Auto" } }
}

public enum SearchEngine: String, CaseIterable, Sendable {
    case google
    case duckduckgoLite
    case duckduckgo
    case bing
    case brave
    case qwant
    case ecosia
    case startpage

    public var displayName: String {
        switch self {
        case .google: return "Google"
        case .duckduckgoLite: return "DuckDuckGo Lite (zéro JS, le plus léger)"
        case .duckduckgo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .brave: return "Brave Search"
        case .qwant: return "Qwant"
        case .ecosia: return "Ecosia"
        case .startpage: return "Startpage"
        }
    }

    /// Short name for messages ("« chat » sur Google").
    public var shortName: String {
        switch self {
        case .duckduckgoLite, .duckduckgo: return "DuckDuckGo"
        default: return displayName
        }
    }

    /// The address a search is sent to (the query goes in the `q` parameter).
    public var queryURL: String {
        switch self {
        case .google: return "https://www.google.com/search"
        case .duckduckgoLite: return "https://lite.duckduckgo.com/lite/"
        case .duckduckgo: return "https://duckduckgo.com/"
        case .bing: return "https://www.bing.com/search"
        case .brave: return "https://search.brave.com/search"
        case .qwant: return "https://www.qwant.com/"
        case .ecosia: return "https://www.ecosia.org/search"
        case .startpage: return "https://www.startpage.com/do/search"
        }
    }

    /// Same address with the query to fill in (`%s`).
    public var template: String { queryURL + "?q=%s" }
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
        static let hibernationGhost = "oree.hibernation.ghost"
        static let protectionExemptHosts = "settings.protectionExemptHosts"
        static let privateByDefault = "settings.privateByDefault"
        static let nightMode = "settings.nightMode"
        static let nightExcludedHosts = "settings.nightExcludedHosts"
        static let nightNativeHosts = "settings.nightNativeHosts"
        static let calmModeEverywhere = "settings.calmModeEverywhere"
        static let digestAutoRecipes = "settings.digestAutoRecipes"
        static let resumeEnabled = "settings.resumeEnabled"
        static let cleanCopy = "settings.cleanCopy"
        static let copyAddsSource = "settings.copyAddsSource"
        static let customHomepageURL = "settings.customHomepageURL"
        static let autoplayMediaAllowed = "settings.autoplayMediaAllowed"
        static let httpsOnly = "settings.httpsOnly"
        static let urlCleaning = "settings.urlCleaning"
        static let fingerprintProtection = "settings.fingerprintProtection"
        static let sendGPC = "settings.sendGlobalPrivacyControl"
        static let minimumFontSize = "settings.minimumFontSize"
        static let clearHistoryOnQuit = "settings.clearHistoryOnQuit"
        static let clearSiteDataOnQuit = "settings.clearSiteDataOnQuit"
        static let safeBrowsingEnabled = "settings.safeBrowsingEnabled"
        static let safeBrowsingAPIKey = "settings.safeBrowsingAPIKey"
        static let webInspectorEnabled = "settings.webInspectorEnabled"
        static let startPageShowsRecent = "settings.startPageShowsRecent"
        static let instantBack = "settings.instantBack"
        static let memoryBudgetMB = "settings.memoryBudgetMB"
        static let backgroundCleanup = "settings.backgroundCleanup"
        static let autoUpdateCheck = "settings.autoUpdateCheck"
        static let lightLongPages = "settings.lightLongPages"
        static let learnSiteMemory = "settings.learnSiteMemory"
        static let appearanceMode = "settings.appearanceMode"
        static let accentHue = "settings.accentHue"
        static let density = "settings.density"
        static let cornerRadius = "settings.cornerRadius"
        static let uiTextOffset = "settings.uiTextOffset"
        static let chromeLayout = "settings.chromeLayout"
        static let aiProvider = "settings.aiProvider"
        static let lucioleMemory = "settings.lucioleMemory"
        static let aiGroqModel = "settings.aiGroqModel"
        static let aiMistralModel = "settings.aiMistralModel"
        static let aiLMStudioModel = "settings.aiLMStudioModel"
        static let aiClaudeCodeModel = "settings.aiClaudeCodeModel"
        static let aiLMStudioURL = "settings.aiLMStudioURL"
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
            Key.hibernationGhost: false,
            Key.protectionExemptHosts: ProtectionPolicy.defaultExemptHosts,
            Key.privateByDefault: false,
            Key.digestAutoRecipes: true,
            Key.resumeEnabled: true,
            Key.cleanCopy: true,
            Key.copyAddsSource: false,
            Key.customHomepageURL: "",
            Key.autoplayMediaAllowed: false,
            Key.httpsOnly: true,
            Key.urlCleaning: true,
            Key.fingerprintProtection: true,
            Key.sendGPC: true,
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
            Key.autoUpdateCheck: true,
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

    /// How Orée presents itself to sites (`HB_UA_MODE` overrides it for tests, without touching the saved setting).
    public var userAgentMode: UserAgentMode {
        get {
            if let forced = ProcessInfo.processInfo.environment["HB_UA_MODE"], let mode = UserAgentMode(rawValue: forced) { return mode }
            return UserAgentMode(rawValue: defaults.string(forKey: "settings.userAgentMode") ?? "") ?? .safari
        }
        set { defaults.set(newValue.rawValue, forKey: "settings.userAgentMode") }
    }
    public var customUserAgent: String {
        get { defaults.string(forKey: "settings.customUserAgent") ?? "" }
        set { defaults.set(newValue, forKey: "settings.customUserAgent") }
    }
    /// Sites that get a Chrome user agent while the mode is Safari (some sites turn Safari-like browsers away).
    public var chromeUserAgentHosts: [String] {
        get { defaults.stringArray(forKey: "settings.chromeUserAgentHosts") ?? [] }
        set { defaults.set(newValue, forKey: "settings.chromeUserAgentHosts") }
    }

    /// Zoom remembered per site (host → factor). Tests and benchmarks (`HB_DB_PATH`) use their own key, never the real one.
    public var siteZoom: [String: Double] {
        get { defaults.dictionary(forKey: Self.siteZoomKey) as? [String: Double] ?? [:] }
        set { defaults.set(newValue, forKey: Self.siteZoomKey) }
    }
    private static let siteZoomKey = "settings.siteZoom" + ProfileContext.keySuffix

    /// Search shortcuts added by the user ("wk" + space + words).
    public var customSearchShortcuts: [SearchShortcut] {
        get { defaults.data(forKey: "settings.customSearchShortcuts").flatMap { try? JSONDecoder().decode([SearchShortcut].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "settings.customSearchShortcuts") }
    }

    /// Where downloads go; empty = the system Downloads folder.
    public var downloadDirectoryPath: String {
        get { defaults.string(forKey: "settings.downloadDirectory") ?? "" }
        set { defaults.set(newValue, forKey: "settings.downloadDirectory") }
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

    /// Experimental "ghost" hibernation (docs/oree-hibernation.md): off by default; `HB_GHOST=1` forces it on.
    public var hibernationGhost: Bool {
        get { GhostPolicy.isEnabled(stored: defaults.bool(forKey: Key.hibernationGhost)) }
        set { defaults.set(newValue, forKey: Key.hibernationGhost) }
    }

    /// Sites with ad blocking and fingerprint noise switched off.
    public var protectionExemptHosts: [String] {
        get { defaults.stringArray(forKey: Key.protectionExemptHosts) ?? ProtectionPolicy.defaultExemptHosts }
        set { defaults.set(newValue, forKey: Key.protectionExemptHosts) }
    }

    /// Sites the user asked never to freeze or sleep.
    public var neverSleepHosts: [String] {
        get { defaults.stringArray(forKey: Key.neverSleepHosts) ?? [] }
        set { defaults.set(newValue, forKey: Key.neverSleepHosts) }
    }

    /// Darkens every site that has no dark theme of its own. `HB_NIGHT=off|auto|always` overrides it (tests).
    public var nightMode: NightMode {
        get {
            if let forced = ProcessInfo.processInfo.environment["HB_NIGHT"].flatMap(NightMode.init(rawValue:)) { return forced }
            return NightMode(rawValue: defaults.string(forKey: Key.nightMode) ?? "") ?? .off
        }
        set { defaults.set(newValue.rawValue, forKey: Key.nightMode) }
    }
    /// Sites the user left light.
    public var nightExcludedHosts: [String] {
        get { defaults.stringArray(forKey: Key.nightExcludedHosts) ?? [] }
        set { defaults.set(newValue, forKey: Key.nightExcludedHosts) }
    }
    /// Sites found to be dark already (learned on the first visit), so they are never inverted.
    public var nightNativeHosts: [String] {
        get { defaults.stringArray(forKey: Key.nightNativeHosts) ?? [] }
        set { defaults.set(newValue, forKey: Key.nightNativeHosts) }
    }

    /// Calm mode on every site: no autoplay until the page is touched, no animations, no notification badges.
    public var calmModeEverywhere: Bool {
        get { defaults.bool(forKey: Key.calmModeEverywhere) }
        set { defaults.set(newValue, forKey: Key.calmModeEverywhere) }
    }

    /// On a recipe page that carries its own structured data, show the essentials at once (no model, instant).
    public var digestAutoRecipes: Bool {
        get { defaults.bool(forKey: Key.digestAutoRecipes) }
        set { defaults.set(newValue, forKey: Key.digestAutoRecipes) }
    }

    /// Remembers video positions and reading positions, and offers to pick up where the user left off.
    public var resumeEnabled: Bool {
        get { defaults.bool(forKey: Key.resumeEnabled) }
        set { defaults.set(newValue, forKey: Key.resumeEnabled) }
    }

    /// Copying from a page puts clean text (no site fonts, colors or links) and real tables on the clipboard.
    public var cleanCopy: Bool {
        get { defaults.bool(forKey: Key.cleanCopy) }
        set { defaults.set(newValue, forKey: Key.cleanCopy) }
    }
    /// A copied quotation gets its source appended, with a link to the exact passage.
    public var copyAddsSource: Bool {
        get { defaults.bool(forKey: Key.copyAddsSource) }
        set { defaults.set(newValue, forKey: Key.copyAddsSource) }
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

    /// Tell sites not to sell or share what the user does (Global Privacy Control: `navigator.globalPrivacyControl`).
    public var sendGlobalPrivacyControl: Bool {
        get { defaults.bool(forKey: Key.sendGPC) }
        set { defaults.set(newValue, forKey: Key.sendGPC) }
    }

    /// The card that shows a picture of a tab when the pointer rests on it.
    public var tabPreviews: Bool {
        get { defaults.object(forKey: "settings.tabPreviews") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "settings.tabPreviews") }
    }

    /// Days without being in front after which a tab goes to the archive (0 = never).
    public var tabArchiveDays: Int {
        get { Int(ProcessInfo.processInfo.environment["HB_ARCHIVE_DAYS"] ?? "") ?? defaults.object(forKey: "settings.tabArchiveDays") as? Int ?? 0 }   // HB_ARCHIVE_DAYS: essais
        set { defaults.set(newValue, forKey: "settings.tabArchiveDays") }
    }

    /// Le journal d'événements (`Docs/journal.md`) : désactivé tant que la personne ne l'a pas choisi. `HB_JOURNAL=1` / `0` : essais seulement.
    public var eventJournalEnabled: Bool {
        get { ProcessInfo.processInfo.environment["HB_JOURNAL"].map { $0 == "1" } ?? (defaults.object(forKey: "settings.eventJournal") as? Bool ?? false) }
        set { defaults.set(newValue, forKey: "settings.eventJournal") }
    }
    /// Combien de jours le journal est gardé (7, 30 ou 90).
    public var eventJournalDays: Int {
        get { [7, 30, 90].contains(defaults.integer(forKey: "settings.eventJournalDays")) ? defaults.integer(forKey: "settings.eventJournalDays") : 30 }
        set { defaults.set(newValue, forKey: "settings.eventJournalDays") }
    }

    /// Retrouver ses favoris et son historique récent dans Spotlight (désactivé par défaut : un historique de navigation est sensible).
    public var spotlightIndexing: Bool {
        get { ProcessInfo.processInfo.environment["HB_SPOTLIGHT"].map { $0 == "1" } ?? (defaults.object(forKey: "settings.spotlight") as? Bool ?? false) }
        set { defaults.set(newValue, forKey: "settings.spotlight") }
    }

    /// Refuser les bannières de cookies automatiquement (jamais « Accepter »). Activé par défaut ; `HB_COOKIE_BANNERS=0` pour les essais.
    public var autoRejectCookieBanners: Bool {
        get { ProcessInfo.processInfo.environment["HB_COOKIE_BANNERS"].map { $0 == "1" } ?? (defaults.object(forKey: "settings.autoRejectCookieBanners") as? Bool ?? true) }
        set { defaults.set(newValue, forKey: "settings.autoRejectCookieBanners") }
    }
    /// Combien de bannières ont été refusées pour la personne (compteur affiché dans les réglages).
    public var cookieBannersRejected: Int {
        get { defaults.integer(forKey: "stats.cookieBannersRejected") }
        set { defaults.set(newValue, forKey: "stats.cookieBannersRejected") }
    }

    /// Gestes de souris (bouton droit + trait) : désactivés par défaut, ils changent ce que fait le clic droit.
    /// Luciole vit dans la page (couche au-dessus de la page) plutôt que dans le panneau latéral. Par défaut : dans la page. Seuls les états du modèle
    /// (à installer, téléchargement, erreur) s'affichent encore dans le panneau, qui s'ouvre alors en renfort.
    public var lucioleInPage: Bool {
        get { ProcessInfo.processInfo.environment["HB_LUCIOLE_PAGE"].map { $0 == "1" } ?? (defaults.object(forKey: "settings.lucioleInPage") as? Bool ?? true) }
        set { defaults.set(newValue, forKey: "settings.lucioleInPage") }
    }

    /// Les gestes de Luciole (Expliquer, Traduire, Garder) apparaissent d'eux-mêmes quand on sélectionne un passage (seulement « dans la page »). Éteint par défaut :
    /// sélectionner sert souvent à copier ; les gestes sont alors dans le clic droit.
    public var lucioleSelectionFan: Bool {
        get { ProcessInfo.processInfo.environment["HB_LUCIOLE_FAN"].map { $0 == "1" } ?? (defaults.object(forKey: "settings.lucioleSelectionFan") as? Bool ?? false) }
        set { defaults.set(newValue, forKey: "settings.lucioleSelectionFan") }
    }

    /// La mémoire ambiante : Orée garde l'extrait des pages lues (jamais en navigation privée, ni connexion, paiement ou mot de passe) pour que Luciole les retrouve. Sur ce Mac seulement.
    public var ambientMemory: Bool {
        get { ProcessInfo.processInfo.environment["HB_AMBIENT_MEMORY"].map { $0 == "1" } ?? (defaults.object(forKey: "settings.ambientMemory") as? Bool ?? true) }
        set { defaults.set(newValue, forKey: "settings.ambientMemory") }
    }
    public var ambientMemoryDays: Int {
        get { max(1, min(365, defaults.object(forKey: "settings.ambientMemoryDays") as? Int ?? 30)) }
        set { defaults.set(newValue, forKey: "settings.ambientMemoryDays") }
    }

    /// Agrandir d'office les vidéos plus petites que leur affichage (bicubique + netteté, WebGL, dans la page). Éteint par défaut : expérimental, et coûteux pour un Mac de 8 Go en mode économie d'énergie.
    /// Éteint, le choix se fait vidéo par vidéo (clic droit › Améliorer cette vidéo).
    public var videoUpscale: Bool {
        get { ProcessInfo.processInfo.environment["HB_VIDEO_UPSCALE"].map { $0 == "1" } ?? (defaults.object(forKey: "settings.videoUpscale") as? Bool ?? false) }
        set { defaults.set(newValue, forKey: "settings.videoUpscale") }
    }
    /// Le moteur d'agrandissement : « apple » (upscaler par apprentissage de macOS 26, affiché par Orée par-dessus la vidéo) ou « webgl » (bicubique + netteté, dans la page).
    public var videoUpscaleEngine: String {
        get { ProcessInfo.processInfo.environment["HB_VIDEO_ENGINE"] ?? (defaults.string(forKey: "settings.videoUpscaleEngine") ?? "apple") }
        set { defaults.set(newValue, forKey: "settings.videoUpscaleEngine") }
    }
    /// La netteté ajoutée (0 à 1) : 0,3 douce, 0,4 normale (défaut), 0,6 forte. Au-delà, elle accentue les défauts de compression (mesuré).
    public var videoUpscaleSharpness: Double {
        get { min(max(defaults.object(forKey: "settings.videoUpscaleSharpness") as? Double ?? 0.4, 0), 1) }
        set { defaults.set(newValue, forKey: "settings.videoUpscaleSharpness") }
    }

    public var mouseGestures: Bool {
        get { ProcessInfo.processInfo.environment["HB_GESTURES"].map { $0 == "1" } ?? (defaults.object(forKey: "settings.mouseGestures") as? Bool ?? false) }
        set { defaults.set(newValue, forKey: "settings.mouseGestures") }
    }

    /// Web apps kept in side panels.
    public var webPanels: [WebPanelEntry] {
        get { (defaults.data(forKey: "settings.webPanels").flatMap { try? JSONDecoder().decode([WebPanelEntry].self, from: $0) }) ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "settings.webPanels") }
    }

    public var energyMode: EnergyMode {
        get {
            if let forced = ProcessInfo.processInfo.environment["HB_ENERGY_MODE"], let mode = EnergyMode(rawValue: forced) { return mode }      // tests
            return EnergyMode(rawValue: defaults.string(forKey: "settings.energyMode") ?? "") ?? .automatic
        }
        set { defaults.set(newValue.rawValue, forKey: "settings.energyMode") }
    }

    /// Sites shown their mobile version (an iPhone identity and mobile content). `HB_UA_MOBILE_HOSTS` (comma separated) overrides it for tests.
    public var mobileSiteHosts: [String] {
        get {
            if let forced = ProcessInfo.processInfo.environment["HB_UA_MOBILE_HOSTS"] { return forced.split(separator: ",").map(String.init) }
            return defaults.stringArray(forKey: "settings.mobileSiteHosts") ?? []
        }
        set { defaults.set(newValue, forKey: "settings.mobileSiteHosts") }
    }

    /// Smallest text size a page may show, in points (0 = the page decides).
    public var minimumFontSize: Int {
        get { max(0, min(defaults.integer(forKey: Key.minimumFontSize), 36)) }
        set { defaults.set(max(0, min(newValue, 36)), forKey: Key.minimumFontSize) }
    }

    /// When Orée quits: forget the browsing history / the cookies and the other data sites keep.
    public var clearHistoryOnQuit: Bool {
        get { defaults.bool(forKey: Key.clearHistoryOnQuit) }
        set { defaults.set(newValue, forKey: Key.clearHistoryOnQuit) }
    }
    public var clearSiteDataOnQuit: Bool {
        get { defaults.bool(forKey: Key.clearSiteDataOnQuit) }
        set { defaults.set(newValue, forKey: Key.clearSiteDataOnQuit) }
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
    /// Looks for a newer release on GitHub at launch (once a day). Off = only the menu item checks.
    public var autoUpdateCheck: Bool {
        get { defaults.bool(forKey: Key.autoUpdateCheck) }
        set { defaults.set(newValue, forKey: Key.autoUpdateCheck) }
    }

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

    /// Luciole garde ses discussions et un journal de ses actions (sur ce Mac seulement, jamais en navigation privée).
    public var lucioleMemoryEnabled: Bool {
        get { defaults.object(forKey: Key.lucioleMemory) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.lucioleMemory) }
    }

    /// Le choix explicite du fournisseur d'IA (nil : pas encore choisi, `AIProvider.effective` décide).
    public var aiProviderChoice: AIProvider? {
        get { (ProcessInfo.processInfo.environment["HB_AI_PROVIDER"] ?? defaults.string(forKey: Key.aiProvider)).flatMap(AIProvider.init(rawValue:)) }      // HB_AI_PROVIDER : essais seulement
        set { defaults.set(newValue?.rawValue, forKey: Key.aiProvider) }
    }
    /// Le modèle utilisé chez un fournisseur en nuage (par défaut : `mistral-small-latest`, `openai/gpt-oss-20b`).
    public func aiModel(for provider: AIProvider) -> String {
        let key = modelKey(provider)
        return defaults.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 } ?? provider.defaultModel
    }
    public func setAIModel(_ model: String, for provider: AIProvider) {
        defaults.set(model.trimmingCharacters(in: .whitespaces), forKey: modelKey(provider))
    }
    private func modelKey(_ provider: AIProvider) -> String { switch provider { case .mistral: Key.aiMistralModel; case .lmstudio: Key.aiLMStudioModel; case .claudeCode: Key.aiClaudeCodeModel; default: Key.aiGroqModel } }

    /// L'adresse de base de LM Studio (par défaut `http://localhost:1234/v1`). `HB_LMSTUDIO_URL` : essais seulement.
    public var lmStudioBase: URL {
        get { LMStudio.normalizedBase(ProcessInfo.processInfo.environment["HB_LMSTUDIO_URL"] ?? defaults.string(forKey: Key.aiLMStudioURL) ?? "") }
        set { defaults.set(newValue.absoluteString, forKey: Key.aiLMStudioURL) }
    }
    public var lmStudioBaseText: String { defaults.string(forKey: Key.aiLMStudioURL) ?? "" }
    public func setLMStudioBase(text: String) { defaults.set(text.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.aiLMStudioURL) }

    /// L'adresse de conversation du fournisseur.
    public func aiEndpoint(for provider: AIProvider) -> URL { provider == .lmstudio ? LMStudio.chatURL(base: lmStudioBase) : provider.endpoint }

    /// Disposition des boutons de la barre d'outils et de la barre latérale (`ChromeLayout`, JSON). Une valeur illisible redonne la disposition d'origine.
    public var chromeLayout: ChromeLayout {
        get { layoutOverride ?? ChromeLayout.decode(defaults.string(forKey: Key.chromeLayout)) }
        set {
            if layoutOverride != nil { layoutOverride = newValue.normalized() }       // essais : jamais dans les vrais réglages
            else { defaults.set(newValue.normalized().json, forKey: Key.chromeLayout) }
        }
    }
    /// `HB_CHROME_LAYOUT=<json>` (essais) : la disposition vit en mémoire seulement, les vrais réglages de la personne ne sont pas touchés.
    private var layoutOverride: ChromeLayout? = ProcessInfo.processInfo.environment["HB_CHROME_LAYOUT"].map { ChromeLayout.decode($0) }

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
            let raw = ProcessInfo.processInfo.environment["HB_SIDEBAR_MODE"] ?? defaults.string(forKey: Key.sidebarMode) ?? ""   // HB_SIDEBAR_MODE: essais
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
        get { TabLayout(rawValue: ProcessInfo.processInfo.environment["HB_TAB_LAYOUT"] ?? defaults.string(forKey: Key.tabLayout) ?? "") ?? .vertical }   // HB_TAB_LAYOUT: essais
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
