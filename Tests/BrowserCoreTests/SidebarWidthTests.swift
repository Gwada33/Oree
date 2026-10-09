import Testing
@testable import BrowserCore

@Suite struct SidebarWidthTests {
    @Test func clampKeepsWidthInRange() {
        #expect(SidebarWidth.clamp(100) == 220)
        #expect(SidebarWidth.clamp(600) == 480)
        #expect(SidebarWidth.clamp(300) == 300)
        #expect(SidebarWidth.clamp(SidebarWidth.standard) == 286)
    }

    @Test func onlyHoverModeOverlaysThePage() {
        #expect(SidebarMode.floating.overlaysPage)
        #expect(!SidebarMode.fixed.overlaysPage && !SidebarMode.hidden.overlaysPage && !SidebarMode.compact.overlaysPage)
    }

    @Test func narrowWindowDoesNotChangeHoverMode() {
        #expect(effectiveSidebarMode(.floating, windowWidth: 700) == .floating)
    }
}
