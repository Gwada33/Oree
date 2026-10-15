import Testing
import Foundation
@testable import BrowserCore

@Suite struct TaskManagerRowsTests {
    private let mb: UInt64 = 1_048_576
    private func tab(_ title: String, pid: Int32?, sleeping: Bool = false, active: Bool = false, audio: Bool = false, frozen: Bool = false) -> TaskManagerRows.TabInfo {
        TaskManagerRows.TabInfo(title: title, host: "\(title).fr", processID: pid, isSleeping: sleeping, isFrozen: frozen, playsAudio: audio, isActive: active)
    }

    @Test func rowsComeBiggestFirstWithTheirState() {
        let a = tab("a", pid: 1, active: true), b = tab("b", pid: 2), c = tab("c", pid: nil, sleeping: true), d = tab("d", pid: 3, audio: true)
        let snap = TaskManagerRows.snapshot(tabs: [a, b, c, d], bytesByProcess: [1: 300 * mb, 2: 500 * mb, 3: 100 * mb])
        #expect(snap.rows.map(\.title) == ["b", "a", "d", "c"])
        #expect(snap.rows.map(\.state) == [.background, .active, .audio, .sleeping])
        #expect(snap.rows.last?.bytes == 0)
    }

    @Test func aProcessSharedByTabsIsSplitButCountedOnceInTheTotal() {
        let snap = TaskManagerRows.snapshot(tabs: [tab("a", pid: 7), tab("b", pid: 7), tab("c", pid: 8)], bytesByProcess: [7: 400 * mb, 8: 100 * mb])
        #expect(snap.rows.filter { $0.processTabs == 2 }.allSatisfy { $0.bytes == 200 * mb })
        #expect(snap.totalBytes == 500 * mb)
    }

    @Test func sleepingTabsAreCreditedWithWhatAnAwakeOneCosts() {
        let snap = TaskManagerRows.snapshot(tabs: [tab("a", pid: 1), tab("b", pid: 2), tab("z", pid: nil, sleeping: true), tab("y", pid: nil, sleeping: true)],
                                            bytesByProcess: [1: 200 * mb, 2: 400 * mb])
        #expect(snap.savedBytes == 2 * 300 * mb)                      // two sleeping tabs × the 300 Mo an awake tab costs on average
        #expect(TaskManagerRows.snapshot(tabs: [tab("a", pid: 1)], bytesByProcess: [1: mb]).savedBytes == nil)
        #expect(TaskManagerRows.snapshot(tabs: [tab("z", pid: nil, sleeping: true)], bytesByProcess: [:]).savedBytes == nil)
    }

    @Test func frozenAndUntitledTabsAreNamedSensibly() {
        let snap = TaskManagerRows.snapshot(tabs: [tab("a", pid: 1, frozen: true), TaskManagerRows.TabInfo(title: "", host: "", processID: nil), TaskManagerRows.TabInfo(title: "", host: "x.fr", processID: nil)],
                                            bytesByProcess: [1: mb])
        #expect(snap.rows.first { $0.state == .frozen } != nil)
        #expect(Set(snap.rows.map(\.title)).isSuperset(of: ["Nouvel onglet", "x.fr"]))
    }

    @Test func memoryIsWrittenInFrench() {
        #expect(TaskManagerRows.memory(412 * mb) == "412 Mo")
        #expect(TaskManagerRows.memory(0) == "0 Mo")
        #expect(TaskManagerRows.memory(1536 * mb) == "1,5 Go")
    }
}
