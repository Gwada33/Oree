import Foundation

/// A visible block of text in a page: its tag, a hash of its text and where it sits in the viewport.
/// The ghost and the real page each produce a list of these; comparing them tells how faithful the ghost was and
/// how far the real page's scroll must move so both show the same thing at the same height.
public struct GhostItem: Codable, Equatable, Sendable {
    public var t: String      // tag
    public var h: UInt32      // hash of the (normalised) text
    public var x: Double
    public var y: Double

    public init(t: String, h: UInt32, x: Double, y: Double) { self.t = t; self.h = h; self.x = x; self.y = y }
}

public enum GhostMatcher {
    /// `JSON.stringify` of an array of items, as returned by the page script. Empty on malformed input.
    public static func parse(_ json: String) -> [GhostItem] {
        json.data(using: .utf8).flatMap { try? JSONDecoder().decode([GhostItem].self, from: $0) } ?? []
    }

    public struct Similarity: Equatable, Sendable {
        /// Share of the ghost's blocks whose text is also visible in the real page.
        public var textMatch: Double
        /// Share of the ghost's blocks found in the real page at the same place (±2 pt).
        public var positionMatch: Double
    }

    public static func similarity(ghost: [GhostItem], real: [GhostItem]) -> Similarity {
        guard !ghost.isEmpty else { return Similarity(textMatch: 1, positionMatch: 1) }
        var text = 0, position = 0
        for item in ghost {
            let same = real.filter { $0.t == item.t && $0.h == item.h }
            if !same.isEmpty { text += 1 }
            if same.contains(where: { abs($0.x - item.x) <= 2 && abs($0.y - item.y) <= 2 }) { position += 1 }
        }
        return Similarity(textMatch: Double(text) / Double(ghost.count), positionMatch: Double(position) / Double(ghost.count))
    }

    /// How much to scroll the real page (`scrollBy(0, dy)`) so the block at the top of the ghost's viewport sits at the
    /// same height in the real page — no jump if content was added or removed above it. nil = no anchor found or the
    /// move would be absurd (> `limit` points), in which case the real page is left where it is.
    public static func scrollDelta(ghost: [GhostItem], real: [GhostItem], limit: Double = 4000) -> Double? {
        guard let anchor = ghost.filter({ $0.y >= 0 }).min(by: { $0.y < $1.y }) else { return nil }
        let candidates = real.filter { $0.t == anchor.t && $0.h == anchor.h }
        guard let match = candidates.min(by: { abs($0.y - anchor.y) < abs($1.y - anchor.y) }) else { return nil }
        let dy = match.y - anchor.y
        return abs(dy) <= limit ? dy : nil
    }
}
