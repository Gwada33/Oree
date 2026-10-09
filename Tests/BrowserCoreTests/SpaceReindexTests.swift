import Testing
@testable import BrowserCore

@Suite struct SpaceReindexTests {
    @Test func tabsShiftDownAfterTheDeletedSpace() {
        #expect(SpaceReindex.newIndex(0, afterDeleting: 1) == 0)
        #expect(SpaceReindex.newIndex(2, afterDeleting: 1) == 1)
        #expect(SpaceReindex.newIndex(3, afterDeleting: 1) == 2)
    }

    @Test func deletedSpaceMovesToPredecessorOrFirst() {
        #expect(SpaceReindex.newIndex(2, afterDeleting: 2) == 1)
        #expect(SpaceReindex.newIndex(0, afterDeleting: 0) == 0)
    }

    @Test func favoritesOfDeletedSpaceBecomeShared() {
        #expect(SpaceReindex.newFavoriteIndex(1, afterDeleting: 1) == nil)
        #expect(SpaceReindex.newFavoriteIndex(nil, afterDeleting: 1) == nil)
        #expect(SpaceReindex.newFavoriteIndex(2, afterDeleting: 1) == 1)
    }
}
