import Testing
import Foundation
@testable import BrowserCore

@Suite struct ChromeLayoutTests {
    private func everyItemOnce(_ layout: ChromeLayout) -> Bool {
        let all = ChromeZone.allCases.flatMap { layout.items(in: $0) }
        return all.count == ChromeItem.allCases.count && Set(all).count == all.count
    }

    @Test func standardLayoutPlacesEveryItemOnce() { #expect(everyItemOnce(.standard)) }

    @Test func movingKeepsEveryItemOnce() {
        var layout = ChromeLayout.standard
        layout.move(.night, to: .sidebarFooter, at: 0)
        layout.move(.reload, to: .toolbarTrailing)
        layout.move(.split, to: .hidden)
        #expect(layout.zone(of: .night) == .sidebarFooter && layout.items(in: .sidebarFooter).first == .night)
        #expect(layout.zone(of: .reload) == .toolbarTrailing && layout.items(in: .toolbarTrailing).last == .reload)
        #expect(layout.zone(of: .split) == .hidden)
        #expect(everyItemOnce(layout))
    }

    @Test func paletteCannotBeHidden() {
        var layout = ChromeLayout.standard
        layout.move(.more, to: .hidden)
        #expect(layout.zone(of: .more) == .toolbarTrailing)
        var broken = ChromeLayout.standard
        broken.zones[.toolbarTrailing]?.removeAll { $0 == .more }
        broken.zones[.hidden] = [.more]
        #expect(broken.normalized().zone(of: .more) == .toolbarTrailing)
    }

    @Test func normalizingRepairsDuplicatesAndMissingItems() {
        let damaged = ChromeLayout(zones: [.toolbarLeading: [.back, .back, .forward], .hidden: [.back]], pinned: [.back, .night], iconSize: .large, showSearchRow: false, showNewTabRow: true)
        let fixed = damaged.normalized()
        #expect(everyItemOnce(fixed))
        #expect(fixed.items(in: .toolbarLeading) == [.back, .forward] + [ChromeItem.sidebarToggle, .reload].filter { fixed.items(in: .toolbarLeading).contains($0) })
        #expect(fixed.pinned == [.night])                      // « épinglé » n'a de sens que pour les boutons selon la page
        #expect(fixed.iconSize == .large && !fixed.showSearchRow)
    }

    @Test func jsonRoundTripsAndGarbageFallsBack() {
        var layout = ChromeLayout.standard
        layout.move(.assistant, to: .toolbarLeading, at: 1)
        layout.pinned = [.essentiel]
        layout.iconSize = .small
        #expect(ChromeLayout.decode(layout.json) == layout)
        #expect(ChromeLayout.decode("pas du json") == .standard)
        #expect(ChromeLayout.decode(nil) == .standard)
    }

    @Test func contextualButtonsAppearOnlyWhenRelevantOrPinned() {
        var layout = ChromeLayout.standard
        let right = { (relevant: Set<ChromeItem>) in layout.visibleItems(in: .toolbarTrailing) { relevant.contains($0) } }
        #expect(right([]) == [.split, .assistant, .customize, .more])
        #expect(right([.essentiel]).contains(.essentiel) && !right([.essentiel]).contains(.calendar))
        layout.pinned = [.calendar]
        #expect(right([]).first == .calendar)                  // épinglé : toujours à sa place, même sans événement
    }
}
