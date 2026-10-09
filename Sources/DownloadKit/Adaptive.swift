import Foundation

/// Decides how many parallel connections a download should use, from the throughput it measures.
/// Hill climbing: add one connection at a time while each one brings at least `gain` more speed (default
/// +10 %); when one doesn't, take it back and stop probing for a while; when the server pushes back
/// (429 / 503) use fewer and wait longer. Pure logic — the caller feeds it throughput samples.
public struct AdaptiveConnections: Sendable {
    public let minimum: Int
    public let maximum: Int
    public private(set) var target: Int
    public let gain: Double
    /// How long to stop adding connections after reaching saturation or after a push-back.
    public let saturatedHold: TimeInterval
    public let pushBackHold: TimeInterval

    private var pendingBaseline: Double?      // throughput measured before the last "add"
    private var lastStep = 1                  // how many connections the last "add" brought (undone together if it did not pay)
    private var holdUntil = Date.distantPast
    public private(set) var isSaturated = false

    public init(minimum: Int = 1, maximum: Int = 16, initial: Int = 2, gain: Double = 0.10,
                saturatedHold: TimeInterval = 20, pushBackHold: TimeInterval = 45) {
        self.minimum = max(1, minimum)
        self.maximum = max(self.minimum, min(maximum, 32))
        self.target = max(self.minimum, min(initial, self.maximum))
        self.gain = gain
        self.saturatedHold = saturatedHold
        self.pushBackHold = pushBackHold
    }

    /// Feed the average throughput (bytes/s) of the last window, measured with `target` connections all busy.
    /// - Parameter canGrow: false near the end of the file (a new connection would not pay off).
    /// - Returns: the (possibly new) number of connections to use.
    @discardableResult
    public mutating func observe(throughput: Double, now: Date = Date(), canGrow: Bool = true) -> Int {
        guard throughput > 0 else { return target }
        if let baseline = pendingBaseline {
            pendingBaseline = nil
            if throughput >= baseline * (1 + gain) {
                // It paid off: keep it and try more — two at a time while the gain is large (slow start), one when it is small.
                if canGrow, target < maximum {
                    pendingBaseline = throughput
                    lastStep = throughput >= baseline * 1.5 ? 2 : 1
                    target = min(maximum, target + lastStep)
                }
            } else {
                // It did not: take it back and stop probing for a while (the link or the server is the limit).
                target = max(minimum, target - lastStep)
                isSaturated = true
                holdUntil = now.addingTimeInterval(saturatedHold)
            }
            return target
        }
        guard now >= holdUntil else { return target }
        isSaturated = false
        if canGrow, target < maximum { pendingBaseline = throughput; lastStep = 1; target += 1 }
        return target
    }

    /// The server answered 429 / 503: back off by one connection and leave it alone for a while.
    public mutating func serverPushedBack(now: Date = Date()) {
        target = max(minimum, target - 1)
        pendingBaseline = nil
        isSaturated = true
        holdUntil = now.addingTimeInterval(pushBackHold)
    }

    /// Stop growing for a while without changing anything (e.g. the download is throttled for browsing).
    public mutating func freeze(until date: Date) { pendingBaseline = nil; holdUntil = max(holdUntil, date) }
}

/// Throughput measured over sliding windows from cumulative byte counts.
public struct ThroughputWindow: Sendable {
    private var lastBytes: Int64?
    private var lastTime: Date?
    public private(set) var current: Double = 0

    public init() {}

    /// Returns bytes/s since the previous call (nil on the first one).
    @discardableResult
    public mutating func sample(bytes: Int64, now: Date = Date()) -> Double? {
        defer { lastBytes = bytes; lastTime = now }
        guard let lastBytes, let lastTime else { return nil }
        let dt = now.timeIntervalSince(lastTime)
        guard dt > 0 else { return nil }
        current = Double(bytes - lastBytes) / dt
        return current
    }

    public mutating func reset() { lastBytes = nil; lastTime = nil; current = 0 }
}
