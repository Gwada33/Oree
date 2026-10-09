import Testing
import Foundation
import Darwin
@testable import BrowserCore

struct MemoryBudgetTests {
    private func tab(_ mb: UInt64, idle: Double = 300, protected: Bool = false) -> MemoryBudget.Candidate {
        .init(id: UUID(), bytes: mb * 1_048_576, idleSeconds: idle, isProtected: protected)
    }
    private func mb(_ value: UInt64) -> UInt64 { value * 1_048_576 }

    @Test func nothingHappensUnderBudget() {
        #expect(MemoryBudget.tabsToSleep(candidates: [tab(300), tab(200)], totalBytes: mb(500), budgetBytes: mb(600)).isEmpty)
    }

    @Test func sleepsTheHeaviestFirstAndStopsOnceUnderBudget() {
        let small = tab(100), big = tab(500), medium = tab(200)
        let chosen = MemoryBudget.tabsToSleep(candidates: [small, big, medium], totalBytes: mb(800), budgetBytes: mb(400))
        #expect(chosen == [big.id])     // 800 - 500 = 300 <= 400, no need to touch the others
    }

    @Test func keepsGoingWhileStillOverBudget() {
        let a = tab(300), b = tab(250), c = tab(100)
        let chosen = MemoryBudget.tabsToSleep(candidates: [a, b, c], totalBytes: mb(650), budgetBytes: mb(150))
        #expect(chosen == [a.id, b.id])  // 650-300=350, 350-250=100 <= 150
    }

    @Test func neverTouchesProtectedOrRecentlyUsedTabs() {
        let playing = tab(900, protected: true), justUsed = tab(700, idle: 5), idle = tab(200)
        let chosen = MemoryBudget.tabsToSleep(candidates: [playing, justUsed, idle], totalBytes: mb(1800), budgetBytes: mb(100))
        #expect(chosen == [idle.id])
    }

    @Test func automaticBudgetIsAQuarterOfRAM() {
        #expect(MemoryBudget.automaticBudgetBytes(physicalMemory: 8 * 1_073_741_824) == 2 * 1_073_741_824)
    }

    @Test func canReadOurOwnFootprint() {
        let bytes = MemoryBudget.footprint(ofProcess: getpid())
        #expect((bytes ?? 0) > 1_000_000)
        #expect(MemoryBudget.footprint(ofProcess: 999_999) == nil)
    }
}
