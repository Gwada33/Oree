import WebKit

/// Builds a `WKProcessPool` with automatic process prewarming disabled.
///
/// WebKit normally keeps a spare, idle "WebContent" renderer process warm in the
/// background (to speed up the next tab/window) via the private
/// `_WKProcessPoolConfiguration.prewarmsProcessesAutomatically` flag. That spare
/// process alone was measured at ~120 MB of real memory for a single open tab.
/// This is undocumented, private WebKit API: every step is guarded so a future
/// macOS/WebKit release that renames or removes it falls back to the normal
/// `WKProcessPool()` instead of crashing.
@MainActor
public enum ProcessPoolFactory {
    /// The pool of normal (non-private) tabs. Created at the very start of the launch, so WebKit can start the
    /// first WebContent process while the window is still being built, instead of after.
    public static let launchPool: WKProcessPool = makeLeanProcessPool()

    /// Starts that first WebContent process now (private WebKit call, guarded: missing = no gain, no harm).
    /// It is the process the first tab needs anyway, so nothing is wasted.
    public static func warmUpFirstProcess() {
        let selector = NSSelectorFromString("_warmInitialProcess")
        guard launchPool.responds(to: selector) else { return }
        _ = launchPool.perform(selector)
    }

    public static func makeLeanProcessPool() -> WKProcessPool {
        guard
            let configClass = NSClassFromString("_WKProcessPoolConfiguration") as? NSObject.Type,
            let poolClass = NSClassFromString("WKProcessPool") as? NSObject.Type
        else {
            return WKProcessPool()
        }

        let config = configClass.init()
        let setPrewarmSelector = NSSelectorFromString("setPrewarmsProcessesAutomatically:")
        guard config.responds(to: setPrewarmSelector) else {
            return WKProcessPool()
        }
        config.setValue(false, forKey: "prewarmsProcessesAutomatically")
        WebKitTuning.applyPoolSettings(to: config)

        let allocSelector = NSSelectorFromString("alloc")
        guard
            let poolClassObject = poolClass as AnyObject as? NSObjectProtocol,
            poolClassObject.responds(to: allocSelector),
            let allocated = poolClassObject.perform(allocSelector)?.takeUnretainedValue() as? NSObject
        else {
            return WKProcessPool()
        }

        let initSelector = NSSelectorFromString("_initWithConfiguration:")
        guard allocated.responds(to: initSelector) else {
            return WKProcessPool()
        }

        guard let pool = allocated.perform(initSelector, with: config)?.takeUnretainedValue() as? WKProcessPool else {
            return WKProcessPool()
        }
        return pool
    }
}
