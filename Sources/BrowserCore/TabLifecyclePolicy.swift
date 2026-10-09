import Foundation

/// Three-tier tab lifecycle: awake → **frozen** (page alive but JavaScript, timers and rendering
/// paused; instant to resume, keeps its RAM until macOS compresses it) → **asleep** (page and
/// process torn down; only a snapshot remains). Everything here is a pure function of numbers so it
/// can be tested without a web view.
public enum TabLifecyclePolicy {
    public enum State: Sendable, Equatable { case awake, frozen }

    /// How much a tab may be touched by the lifecycle.
    public enum Exemption: Sendable, Equatable {
        case none
        /// Unsaved form input / editor content: may be frozen, never torn down.
        case noSleep
        /// On screen, playing media, camera/mic, messaging, "never sleep" site: left completely alone.
        case full
    }

    public struct Entry: Sendable, Equatable {
        public let id: UUID
        public let bytes: UInt64
        public let idleSeconds: Double
        public let state: State
        public let exemption: Exemption
        /// 1 = normal. Lower = this tab is more worth keeping (current space, pinned, often visited).
        public let keepWeight: Double
        /// This tab's own time-to-sleep (other space, heavy site…); nil = `Timing.sleepAfter`. 0 = never.
        public let sleepAfter: Double?

        public init(id: UUID, bytes: UInt64, idleSeconds: Double, state: State, exemption: Exemption,
                    keepWeight: Double = 1, sleepAfter: Double? = nil) {
            self.id = id; self.bytes = bytes; self.idleSeconds = idleSeconds
            self.state = state; self.exemption = exemption; self.keepWeight = keepWeight; self.sleepAfter = sleepAfter
        }

        /// Bigger = better candidate to sleep: memory × time unused, discounted by `keepWeight`.
        public var score: Double { Double(bytes) * max(idleSeconds, 1) * keepWeight }
    }

    public struct Plan: Sendable, Equatable {
        public var freeze: [UUID] = []
        public var sleep: [UUID] = []
        public init(freeze: [UUID] = [], sleep: [UUID] = []) { self.freeze = freeze; self.sleep = sleep }
        public var isEmpty: Bool { freeze.isEmpty && sleep.isEmpty }
    }

    public struct Timing: Sendable, Equatable {
        /// Hidden this long → frozen. 0 disables freezing.
        public var freezeAfter: Double
        /// Hidden this long → torn down. 0 disables time-based sleeping.
        public var sleepAfter: Double
        /// A tab touched more recently than this is never chosen for a memory-budget decision
        /// (switching between two tabs must not make them sleep and wake in a loop).
        public var minimumIdle: Double
        /// When over budget, keep sleeping until the total is down to this share of the budget.
        public var hysteresis: Double

        public init(freezeAfter: Double = 120, sleepAfter: Double = 2700, minimumIdle: Double = 20, hysteresis: Double = 0.8) {
            self.freezeAfter = freezeAfter; self.sleepAfter = sleepAfter
            self.minimumIdle = minimumIdle; self.hysteresis = hysteresis
        }
    }

    /// What to do on one periodic pass.
    /// - Time rules: hidden `freezeAfter` → freeze; hidden `sleepAfter` → sleep (unless exempt/dirty).
    /// - Budget rule: over budget → sleep by decreasing score until the total reaches
    ///   `hysteresis × budget`; a tab with unsaved input is frozen instead of slept.
    public static func plan(entries: [Entry], budgetBytes: UInt64, timing: Timing) -> Plan {
        var plan = Plan()
        var slept = Set<UUID>()
        var remaining = entries.reduce(UInt64(0)) { $0 + $1.bytes }

        for e in entries where e.exemption != .full {
            let limit = e.sleepAfter ?? timing.sleepAfter
            if limit > 0, e.idleSeconds >= limit, e.exemption == .none {
                plan.sleep.append(e.id); slept.insert(e.id); remaining -= min(remaining, e.bytes)
            }
        }

        if remaining > budgetBytes {
            let target = UInt64(Double(budgetBytes) * timing.hysteresis)
            let candidates = entries
                .filter { $0.exemption != .full && !slept.contains($0.id) && $0.idleSeconds >= timing.minimumIdle }
                .sorted { $0.score > $1.score }
            for e in candidates where remaining > target {
                if e.exemption == .none {
                    plan.sleep.append(e.id); slept.insert(e.id); remaining -= min(remaining, e.bytes)
                }
                // `.noSleep` tabs can't give memory back; the freeze rule below still covers them.
            }
        }

        if timing.freezeAfter > 0 {
            for e in entries where e.exemption != .full && e.state == .awake && !slept.contains(e.id) && e.idleSeconds >= timing.freezeAfter {
                plan.freeze.append(e.id)
            }
        }
        return plan
    }

    /// Memory pressure from the OS: everything that may be slept goes; tabs with unsaved input are frozen.
    public static func emergencyPlan(entries: [Entry]) -> Plan {
        var plan = Plan()
        for e in entries.sorted(by: { $0.score > $1.score }) {
            switch e.exemption {
            case .none: plan.sleep.append(e.id)
            case .noSleep: if e.state == .awake { plan.freeze.append(e.id) }
            case .full: break
            }
        }
        return plan
    }
}

/// Sites whose tabs must keep running while hidden (they deliver messages / calls) and the
/// user's own "never sleep" list.
public enum SleepExemptions {
    public static let messagingHosts: Set<String> = [
        "web.whatsapp.com", "web.telegram.org", "app.slack.com", "discord.com", "teams.microsoft.com",
        "messenger.com", "www.messenger.com", "app.element.io", "mail.google.com", "outlook.live.com",
        "outlook.office.com", "meet.google.com", "zoom.us", "app.zoom.us",
    ]

    public static func isExempt(host: String?, userHosts: [String]) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if messagingHosts.contains(host) || messagingHosts.contains(bare) { return true }
        return userHosts.contains { $0 == host || $0 == bare }
    }
}
