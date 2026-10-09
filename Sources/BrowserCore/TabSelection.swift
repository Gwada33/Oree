import Foundation

/// Pure rules for which tab to show after the set of tabs changes, with tabs grouped
/// into spaces (each tab has a space number; only one space is visible at a time).
public enum TabSelection {
    /// After closing the tab that was at `removedIndex`, which tab (index into the array
    /// *after* removal) should be selected? The closest one in the same space — the next one
    /// first, else the previous one — or `nil` if that space has no tabs left.
    /// - Parameter spaces: each remaining tab's space number, in order.
    public static func neighbor(afterRemovingIndex removedIndex: Int, spaces: [Int], space: Int) -> Int? {
        let after = spaces.indices.filter { $0 >= removedIndex && spaces[$0] == space }
        if let next = after.first { return next }
        return spaces.indices.last { $0 < removedIndex && spaces[$0] == space }
    }

    /// The global array index a moved tab should take when it moves `offset` rows
    /// within its own space (hidden tabs of other spaces are skipped over). `nil` if it can't move.
    public static func destinationIndex(of index: Int, offset: Int, spaces: [Int]) -> Int? {
        guard spaces.indices.contains(index) else { return nil }
        let space = spaces[index]
        let sameSpace = spaces.indices.filter { spaces[$0] == space }
        guard let position = sameSpace.firstIndex(of: index) else { return nil }
        let target = max(0, min(sameSpace.count - 1, position + offset))
        return target == position ? nil : sameSpace[target]
    }
}
