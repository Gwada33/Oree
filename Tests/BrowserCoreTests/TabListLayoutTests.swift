import Testing
import Foundation
@testable import BrowserCore

@Suite struct TabListLayoutTests {
    let g1 = TabGroup(name: "Recherche", spaceIndex: 0)
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    @Test func noGroupsMeansPlainList() {
        let rows = TabListLayout.rows(tabs: [.init(id: a, spaceIndex: 0, groupID: nil), .init(id: b, spaceIndex: 1, groupID: nil)], groups: [], space: 0)
        #expect(rows == [.tab(a, indented: false)])
    }

    @Test func groupedAndLooseTabsAreSeparated() {
        let tabs: [TabListLayout.Item] = [
            .init(id: a, spaceIndex: 0, groupID: nil),
            .init(id: b, spaceIndex: 0, groupID: g1.id),
            .init(id: c, spaceIndex: 0, groupID: g1.id),
        ]
        let rows = TabListLayout.rows(tabs: tabs, groups: [g1], space: 0)
        #expect(rows == [.groupHeader(g1.id), .tab(b, indented: true), .tab(c, indented: true), .looseHeader, .tab(a, indented: false)])
    }

    @Test func collapsedGroupHidesItsTabs() {
        var g = g1; g.collapsed = true
        let tabs: [TabListLayout.Item] = [.init(id: b, spaceIndex: 0, groupID: g.id)]
        #expect(TabListLayout.rows(tabs: tabs, groups: [g], space: 0) == [.groupHeader(g.id)])
        #expect(TabListLayout.hiddenCount(in: g, tabs: tabs) == 1)
    }

    @Test func orphanGroupIDFallsBackToLoose() {
        let rows = TabListLayout.rows(tabs: [.init(id: d, spaceIndex: 0, groupID: UUID())], groups: [], space: 0)
        #expect(rows == [.tab(d, indented: false)])
    }

    @Test func groupsOfOtherSpacesAreIgnored() {
        let other = TabGroup(name: "X", spaceIndex: 2)
        #expect(TabListLayout.rows(tabs: [], groups: [other], space: 0).isEmpty)
    }
}
