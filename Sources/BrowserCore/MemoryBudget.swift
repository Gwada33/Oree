import Foundation
import Darwin

/// Keeps the tabs' total memory under a budget by putting the heaviest hidden tabs to sleep.
/// The decision itself is a pure function so it can be tested without any web view.
public enum MemoryBudget {
    public struct Candidate: Sendable, Equatable {
        public let id: UUID
        public let bytes: UInt64
        public let idleSeconds: Double
        /// Active tab, or one playing media — never put to sleep.
        public let isProtected: Bool

        public init(id: UUID, bytes: UInt64, idleSeconds: Double, isProtected: Bool) {
            self.id = id; self.bytes = bytes; self.idleSeconds = idleSeconds; self.isProtected = isProtected
        }
    }

    /// Which tabs to sleep (heaviest first) so the total drops to `budgetBytes`.
    /// A tab touched less than `minimumIdle` seconds ago is left alone (switching back and
    /// forth between two tabs must not make them sleep and wake in a loop).
    public static func tabsToSleep(candidates: [Candidate], totalBytes: UInt64, budgetBytes: UInt64, minimumIdle: Double = 20) -> [UUID] {
        guard totalBytes > budgetBytes else { return [] }
        var remaining = totalBytes
        var chosen: [UUID] = []
        for tab in candidates.filter({ !$0.isProtected && $0.idleSeconds >= minimumIdle }).sorted(by: { $0.bytes > $1.bytes }) {
            if remaining <= budgetBytes { break }
            chosen.append(tab.id)
            remaining -= min(remaining, tab.bytes)
        }
        return chosen
    }

    /// A quarter of the machine's memory: 2 GB on an 8 GB Mac.
    public static func automaticBudgetBytes(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> UInt64 {
        physicalMemory / 4
    }

    /// The process's memory footprint (what Activity Monitor shows as "Mémoire"), or nil if unreadable.
    public static func footprint(ofProcess pid: Int32) -> UInt64? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? info.ri_phys_footprint : nil
    }
}
