import Testing
@testable import BrowserCore

struct TabSelectionTests {
    @Test func prefersTheNextTabInTheSameSpace() {
        // tabs after removal: [space0, space1, space0, space0]; removed one sat at index 1
        #expect(TabSelection.neighbor(afterRemovingIndex: 1, spaces: [0, 1, 0, 0], space: 0) == 2)
    }

    @Test func fallsBackToThePreviousTabInTheSameSpace() {
        #expect(TabSelection.neighbor(afterRemovingIndex: 3, spaces: [0, 1, 0], space: 0) == 2)
        #expect(TabSelection.neighbor(afterRemovingIndex: 2, spaces: [1, 0, 1], space: 0) == 1)
    }

    @Test func skipsTabsOfOtherSpaces() {
        #expect(TabSelection.neighbor(afterRemovingIndex: 0, spaces: [1, 1, 0], space: 0) == 2)
    }

    @Test func returnsNilWhenTheSpaceIsEmpty() {
        #expect(TabSelection.neighbor(afterRemovingIndex: 1, spaces: [1, 2], space: 0) == nil)
        #expect(TabSelection.neighbor(afterRemovingIndex: 0, spaces: [], space: 0) == nil)
    }

    @Test func movesOverHiddenTabsOfOtherSpaces() {
        // visible (space 0) tabs sit at global indices 0, 2, 3; moving index 0 down one row lands on 2
        #expect(TabSelection.destinationIndex(of: 0, offset: 1, spaces: [0, 1, 0, 0]) == 2)
        #expect(TabSelection.destinationIndex(of: 3, offset: -2, spaces: [0, 1, 0, 0]) == 0)
    }

    @Test func clampsAndRefusesNoOpMoves() {
        #expect(TabSelection.destinationIndex(of: 3, offset: 5, spaces: [0, 1, 0, 0]) == nil)   // already last
        #expect(TabSelection.destinationIndex(of: 0, offset: 9, spaces: [0, 0, 0]) == 2)
        #expect(TabSelection.destinationIndex(of: 5, offset: 1, spaces: [0]) == nil)
    }
}
