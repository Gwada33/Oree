import Foundation

/// Index bookkeeping when a space is deleted (tabs/groups/favorites refer to spaces by position).
public enum SpaceReindex {
    /// Where an item that lived in space `index` ends up after space `deleted` is removed.
    /// Items of the deleted space move to its predecessor (or to the new first space).
    public static func newIndex(_ index: Int, afterDeleting deleted: Int) -> Int {
        if index < deleted { return index }
        if index > deleted { return index - 1 }
        return max(0, deleted - 1)
    }

    /// Same for optional indexes where `nil` means "every space" (favorites).
    /// A favorite of the deleted space becomes shared, so nothing the user saved disappears.
    public static func newFavoriteIndex(_ index: Int?, afterDeleting deleted: Int) -> Int? {
        guard let index else { return nil }
        return index == deleted ? nil : newIndex(index, afterDeleting: deleted)
    }
}
