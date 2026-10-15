import Foundation

/// What the task manager shows: one line per tab with the memory its page costs, biggest first.
public enum TaskManagerRows {
    public struct TabInfo: Equatable, Sendable {
        public var id: UUID
        public var title: String
        public var host: String
        /// The web process this tab's page lives in (nil when it has none: asleep, or not loaded yet).
        public var processID: Int32?
        public var isSleeping: Bool
        public var isFrozen: Bool
        public var playsAudio: Bool
        public var isActive: Bool

        public init(id: UUID = UUID(), title: String, host: String = "", processID: Int32?, isSleeping: Bool = false, isFrozen: Bool = false, playsAudio: Bool = false, isActive: Bool = false) {
            self.id = id; self.title = title; self.host = host; self.processID = processID
            self.isSleeping = isSleeping; self.isFrozen = isFrozen; self.playsAudio = playsAudio; self.isActive = isActive
        }
    }

    public enum State: String, Sendable { case active = "Actif", background = "En arrière-plan", frozen = "Figé", sleeping = "En veille", audio = "Joue du son" }

    public struct Row: Equatable, Sendable {
        public var id: UUID
        public var title: String
        public var host: String
        /// This tab's share of its process (a process serving several tabs is split between them).
        public var bytes: UInt64
        /// How many tabs live in the same process (1 = alone).
        public var processTabs: Int
        public var state: State
    }

    public struct Snapshot: Equatable, Sendable {
        public var rows: [Row]
        /// What the web processes cost altogether (each counted once, even when several tabs share it).
        public var totalBytes: UInt64
        /// What sleeping tabs avoid: the average cost of an awake tab for each sleeping one (nil if none is asleep or none is awake).
        public var savedBytes: UInt64?
    }

    public static func snapshot(tabs: [TabInfo], bytesByProcess: [Int32: UInt64]) -> Snapshot {
        let perProcess = Dictionary(grouping: tabs.compactMap(\.processID), by: { $0 }).mapValues(\.count)
        let rows: [Row] = tabs.map { tab in
            let shared = tab.processID.flatMap { perProcess[$0] } ?? 1
            let bytes = tab.processID.flatMap { bytesByProcess[$0] }.map { $0 / UInt64(max(shared, 1)) } ?? 0
            let state: State = tab.isSleeping ? .sleeping : tab.isFrozen ? .frozen : tab.playsAudio ? .audio : tab.isActive ? .active : .background
            return Row(id: tab.id, title: tab.title.isEmpty ? (tab.host.isEmpty ? "Nouvel onglet" : tab.host) : tab.title, host: tab.host, bytes: bytes, processTabs: shared, state: state)
        }.sorted { $0.bytes > $1.bytes }
        let awake = rows.filter { $0.state != .sleeping && $0.bytes > 0 }
        let asleep = rows.filter { $0.state == .sleeping }
        let saved: UInt64? = (asleep.isEmpty || awake.isEmpty) ? nil : UInt64(asleep.count) * (awake.map(\.bytes).reduce(0, +) / UInt64(awake.count))
        return Snapshot(rows: rows, totalBytes: bytesByProcess.values.reduce(0, +), savedBytes: saved)
    }

    /// "412 Mo", "1,3 Go", "0 Mo".
    public static func memory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f Go", mb / 1024).replacingOccurrences(of: ".", with: ",") }
        return "\(Int(mb.rounded())) Mo"
    }
}
