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
    static let defaultFeatures: [(String, Bool)] = []

    /// Sets internal WebKit feature flags on a preferences object. Returns the keys that were applied.
    @discardableResult
    public static func applyFeatures(to preferences: WKPreferences) -> [String] {
        let wanted = defaultFeatures + overrides("HB_WK_FEATURES")
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
        WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeMemoryCache], modifiedSince: .distantPast) {}
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
