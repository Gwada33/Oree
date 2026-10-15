import Foundation

/// "Mode économie d'énergie": when it is on, Orée is less patient with tabs nobody looks at (they are frozen and put to sleep sooner),
/// which saves processor time and battery. It follows the Mac's own Low Power Mode unless the user decides otherwise.
public enum EnergyMode: String, CaseIterable, Sendable {
    case automatic, always, never

    public var label: String {
        switch self {
        case .automatic: return "Automatique (quand le Mac est en mode économie d’énergie)"
        case .always: return "Toujours"
        case .never: return "Jamais"
        }
    }
}

public enum EnergyPolicy {
    public static func isActive(mode: EnergyMode, systemLowPower: Bool) -> Bool {
        switch mode {
        case .automatic: return systemLowPower
        case .always: return true
        case .never: return false
        }
    }

    /// The timings with the patience halved (0 stays 0: a disabled step stays disabled), but never so short that switching tabs would
    /// make them sleep at once: at least 30 s before freezing, 2 min before sleeping.
    public static func adjusted(_ timing: TabLifecyclePolicy.Timing, active: Bool) -> TabLifecyclePolicy.Timing {
        guard active else { return timing }
        var result = timing
        if timing.freezeAfter > 0 { result.freezeAfter = min(timing.freezeAfter, max(30, timing.freezeAfter / 2)) }
        if timing.sleepAfter > 0 { result.sleepAfter = min(timing.sleepAfter, max(120, timing.sleepAfter / 2)) }
        return result
    }
}
