import WebKit
import ObjectiveC

/// Access to WebKit's *internal* feature flags and process-pool switches.
///
/// These are private, undocumented and can change with any macOS update, so every
/// access is guarded: an unknown key or a missing selector is skipped silently and
/// WebKit simply keeps its default. Nothing here is required for the browser to work.
///
/// For experiments, settings can be forced from the environment:
///   HB_WK_FEATURES="HiddenPageDOMTimerThrottlingAutoIncreases=1,RequestIdleCallbackEnabled=1"
///   HB_WK_POOL="usesWebProcessCache=0,pageCacheEnabled=0"
@MainActor
public enum WebKitTuning {
    /// Parses "a=1,b=0" from an environment variable.
    static func overrides(_ variable: String) -> [(String, Bool)] {
        (ProcessInfo.processInfo.environment[variable] ?? "").split(separator: ",").compactMap { pair in
            let parts = pair.split(separator: "=")
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), parts[1] == "1")
        }
    }

    /// Flags we deliberately turn on/off for every web view (key, value).
    /// Chosen only after measuring; see scripts/bench.
    static var defaultFeatures: [(String, Bool)] { SettingsStore.shared.webkitTuning ? tunedFeatures : [] }

    /// Réglages retenus (clés WebKit de macOS 26/27 ; une clé inconnue est ignorée, voir `applyFeatures`). Rien qui touche à la sécurité ni à la vie privée.
    static let tunedFeatures: [(String, Bool)] = [
        // Vitesse : préchargement des pages et des médias, animations et filtres hors du fil principal.
        ("LinkPrefetchEnabled", true), ("SpeculationRulesPrefetchEnabled", true), ("MediaPreloadingEnabled", true),
        ("AcceleratedCompositingForFixedPositionEnabled", true), ("AcceleratedFiltersEnabled", true), ("ThreadedTimeBasedAnimationsEnabled", true),
        ("PreferPageRenderingUpdatesNear60FPSEnabled", false),            // suit la fréquence de l'écran (120 Hz sur ProMotion) au lieu de 60
        // Économie : un onglet caché est ralenti de plus en plus.
        ("HiddenPageDOMTimerThrottlingAutoIncreases", true),
        // Confort : API et CSS que Safari n'active pas encore, correctifs de sites cassés, recherche dans les sous-titres.
        ("RequestIdleCallbackEnabled", true), ("DynamicSiteInterventionsEnabled", true), ("FindInVideoEnabled", true), ("TextTracksInMSEEnabled", true),
        ("ImageAnalysisDuringFindInPageEnabled", true), ("InputTypeMonthEnabled", true), ("InputTypeWeekEnabled", true), ("SelectShowPickerEnabled", true),
        ("CloseWatcherEnabled", true), ("LoginStatusAPIEnabled", true),
        ("CSSLineClampEnabled", true), ("CSSOverflowClipMarginEnabled", true), ("CSSTextJustifyEnabled", true), ("CSSTextSpacingTrimEnabled", true),
        ("CSSFontVariantEmojiEnabled", true), ("CSSAppearanceBaseEnabled", true), ("CSSScrollStateContainerQueriesEnabled", true),
    ]

    /// Sets internal WebKit feature flags on a preferences object. Returns the keys that were applied.
    @discardableResult
    public static func applyFeatures(to preferences: WKPreferences) -> [String] {
        let wanted = defaultFeatures + overrides("HB_WK_FEATURES")
        applyProperties(to: preferences)
        guard !wanted.isEmpty,
              let featuresList = (WKPreferences.self as AnyObject).perform(NSSelectorFromString("_features"))?.takeUnretainedValue() as? [NSObject]
        else { return [] }

        let setter = NSSelectorFromString("_setEnabled:forFeature:")
        guard preferences.responds(to: setter), let imp = preferences.method(for: setter) else { return [] }
        typealias Function = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        let call = unsafeBitCast(imp, to: Function.self)

        var applied: [String] = []
        for (key, value) in wanted {
            guard let feature = featuresList.first(where: { ($0.value(forKey: "key") as? String) == key }) else { continue }
            call(preferences, setter, value, feature)
            applied.append(key)
        }
        return applied
    }

    /// Réglages privés de `WKPreferences` qui ne sont pas des « features » (propriétés Objective-C), posés par clé ; une clé inconnue est ignorée.
    /// Essais : HB_WK_PREFS="_dnsPrefetchingEnabled=1".
    static let tunedProperties: [(String, Bool)] = []                 // rien de retenu : voir scripts/bench/webkit_pool_ab.py

    static func applyProperties(to preferences: WKPreferences) {
        for (key, value) in tunedProperties + overrides("HB_WK_PREFS") {
            guard let property = class_getProperty(WKPreferences.self, key) else { continue }
            let custom = property_copyAttributeValue(property, "S")
            defer { free(custom) }
            let setter = NSSelectorFromString(custom.map { String(cString: $0) } ?? "set\(key.prefix(1).uppercased())\(key.dropFirst()):")
            guard preferences.responds(to: setter), let imp = preferences.method(for: setter) else { continue }
            unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector, Bool) -> Void).self)(preferences, setter, value)
        }
    }

    /// Process-pool switches, set by key on the private `_WKProcessPoolConfiguration`.
    static func applyPoolSettings(to configuration: NSObject) {
        for (key, value) in defaultPoolSettings + overrides("HB_WK_POOL") {
            let setter = NSSelectorFromString("set\(key.prefix(1).uppercased())\(key.dropFirst()):")
            if configuration.responds(to: setter) { configuration.setValue(value, forKey: key) }
        }
    }

    /// Pool switches applied to every launch (chosen from measurements, see scripts/bench/webkit_ab.py).
    static var defaultPoolSettings: [(String, Bool)] {
        [("pageCacheEnabled", SettingsStore.shared.instantBack)]
    }

    /// Reads WebKit's own process bookkeeping — handy to check that a setting really changed something.
    public static func processReport(for pool: WKProcessPool) -> String {
        let keys = ["_webProcessCount", "_webProcessCountIgnoringPrewarmedAndCached", "_hasPrewarmedWebProcess",
                    "_processCacheSize", "_processCacheCapacity", "_maximumSuspendedPageCount", "_serviceWorkerProcessCount"]
        return keys.map { key in "\(key.dropFirst())=\(pool.value(forKey: key).map { "\($0)" } ?? "n/a")" }.joined(separator: " ")
    }

    /// Forces a JavaScript garbage collection in every web process of the pool, which hands back
    /// memory held by dead objects. Uses the call WebKit's own tests use, so it is guarded:
    /// returns false if it no longer exists.
    @discardableResult
    public static func collectJavaScriptGarbage(in pool: WKProcessPool) -> Bool {
        let selector = NSSelectorFromString("_garbageCollectJavaScriptObjectsForTesting")
        guard pool.responds(to: selector) else { return false }
        _ = pool.perform(selector)
        return true
    }

    /// Drops WebKit's in-memory caches (decoded resources) for the default data store.
    public static func purgeMemoryCaches() {
        ProfileContext.dataStore.removeData(ofTypes: [WKWebsiteDataTypeMemoryCache], modifiedSince: .distantPast) {}
    }

    /// Asks WebKit's network process to open a connection to `url`'s host ahead of the real request.
    @discardableResult
    public static func preconnect(to url: URL, using pool: WKProcessPool) -> Bool {
        let selector = NSSelectorFromString("_preconnectToServer:")
        guard pool.responds(to: selector) else { return false }
        _ = pool.perform(selector, with: url)
        return true
    }
}
