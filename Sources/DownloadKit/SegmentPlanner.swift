import Foundation

/// One byte range of the file, filled from `start` to `end` (exclusive) by one connection at a time.
public struct Segment: Codable, Sendable, Equatable {
    public var start: Int64
    public var end: Int64
    /// Next byte still to fetch (`start` + bytes already on disk).
    public var next: Int64

    public init(start: Int64, end: Int64, next: Int64? = nil) {
        self.start = start; self.end = end; self.next = next ?? start
    }

    public var remaining: Int64 { max(0, end - next) }
    public var isComplete: Bool { next >= end }
    public var written: Int64 { max(0, next - start) }
}

/// Pure rules for cutting a file into segments and re-cutting while it downloads.
public enum SegmentPlanner {
    /// A segment smaller than this isn't worth its own connection.
    public static let minimumSegment: Int64 = 1 << 20

    /// Cuts `[0, total)` into at most `connections` contiguous, gap-free segments.
    public static func initial(total: Int64, connections: Int, minimumSegment: Int64 = SegmentPlanner.minimumSegment) -> [Segment] {
        guard total > 0 else { return [] }
        let byMinimum = max(1, Int(total / max(1, minimumSegment)))
        let count = max(1, min(connections, byMinimum))
        let base = total / Int64(count)
        var result: [Segment] = []
        var cursor: Int64 = 0
        for i in 0..<count {
            let end = i == count - 1 ? total : cursor + base
            result.append(Segment(start: cursor, end: end))
            cursor = end
        }
        return result
    }

    /// Splits the segment with the most bytes left in two (when worth it) so a freed connection can help.
    /// The original keeps its start and now ends at the midpoint; the new segment takes the second half.
    /// - Returns: index of the new segment, or nil if nothing is big enough to split.
    @discardableResult
    public static func splitLargest(_ segments: inout [Segment], minimumSplit: Int64 = SegmentPlanner.minimumSegment) -> Int? {
        guard let index = segments.indices.max(by: { segments[$0].remaining < segments[$1].remaining }),
              segments[index].remaining >= minimumSplit * 2 else { return nil }
        let mid = segments[index].next + segments[index].remaining / 2
        let tail = Segment(start: mid, end: segments[index].end)
        segments[index].end = mid
        segments.append(tail)
        return segments.count - 1
    }

    /// Bytes already on disk across all segments.
    public static func received(_ segments: [Segment]) -> Int64 { segments.reduce(0) { $0 + $1.written } }

    /// True when the segments tile `[0, total)` exactly (no gap, no overlap).
    public static func tiles(_ segments: [Segment], total: Int64) -> Bool {
        let sorted = segments.sorted { $0.start < $1.start }
        var cursor: Int64 = 0
        for s in sorted {
            guard s.start == cursor, s.end >= s.start, s.next >= s.start, s.next <= s.end else { return false }
            cursor = s.end
        }
        return cursor == total
    }
}
