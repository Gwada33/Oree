import Testing
import Foundation
@testable import BrowserCore

@Suite struct TabLifecyclePolicyTests {
    private let mb: UInt64 = 1_048_576
    private func entry(_ mbytes: UInt64, idle: Double, state: TabLifecyclePolicy.State = .awake,
                       _ exemption: TabLifecyclePolicy.Exemption = .none, weight: Double = 1) -> TabLifecyclePolicy.Entry {
        .init(id: UUID(), bytes: mbytes * mb, idleSeconds: idle, state: state, exemption: exemption, keepWeight: weight)
    }
    private let timing = TabLifecyclePolicy.Timing(freezeAfter: 120, sleepAfter: 2700, minimumIdle: 20, hysteresis: 0.8)

    @Test func freshTabsAreLeftAlone() {
        let plan = TabLifecyclePolicy.plan(entries: [entry(300, idle: 30)], budgetBytes: 2000 * mb, timing: timing)
        #expect(plan.isEmpty)
    }

    @Test func hiddenTabIsFrozenThenSleptByTime() {
        let a = entry(300, idle: 200), b = entry(300, idle: 3000, state: .frozen)
        let plan = TabLifecyclePolicy.plan(entries: [a, b], budgetBytes: 4000 * mb, timing: timing)
        #expect(plan.freeze == [a.id])
        #expect(plan.sleep == [b.id])
    }

    @Test func fullyExemptTabIsNeverTouched() {
        let a = entry(900, idle: 99_999, .full)
        #expect(TabLifecyclePolicy.plan(entries: [a], budgetBytes: 1, timing: timing).isEmpty)
        #expect(TabLifecyclePolicy.emergencyPlan(entries: [a]).isEmpty)
    }

    @Test func dirtyTabIsFrozenButNeverSlept() {
        let a = entry(900, idle: 99_999, .noSleep)
        let plan = TabLifecyclePolicy.plan(entries: [a], budgetBytes: 1, timing: timing)
        #expect(plan.sleep.isEmpty)
        #expect(plan.freeze == [a.id])
        #expect(TabLifecyclePolicy.emergencyPlan(entries: [a]).sleep.isEmpty)
    }

    @Test func overBudgetSleepsBestScoreFirstDownToEightyPercent() {
        // total 1000 MB, budget 800 → target 640 MB
        let big = entry(400, idle: 300), mid = entry(300, idle: 300), small = entry(300, idle: 300)
        let plan = TabLifecyclePolicy.plan(entries: [small, mid, big], budgetBytes: 800 * mb, timing: timing)
        #expect(plan.sleep.first == big.id)           // heaviest × same idle
        #expect(plan.sleep.count == 2)                // 1000 → 600 ≤ 640, then stop
    }

    @Test func recentlyUsedTabsAreSkippedByBudgetRule() {
        let recent = entry(900, idle: 5), old = entry(100, idle: 500)
        let plan = TabLifecyclePolicy.plan(entries: [recent, old], budgetBytes: 500 * mb, timing: timing)
        #expect(plan.sleep == [old.id])
    }

    @Test func keepWeightLowersTheScore() {
        let current = entry(300, idle: 300, weight: 0.5), other = entry(300, idle: 300)
        let plan = TabLifecyclePolicy.plan(entries: [current, other], budgetBytes: 450 * mb, timing: timing)
        #expect(plan.sleep.first == other.id)
    }

    @Test func perTabSleepLimitOverridesTiming() {
        let e = TabLifecyclePolicy.Entry(id: UUID(), bytes: mb, idleSeconds: 130, state: .awake, exemption: .none, sleepAfter: 120)
        #expect(TabLifecyclePolicy.plan(entries: [e], budgetBytes: UInt64.max, timing: timing).sleep == [e.id])
    }

    @Test func exemptionsRecognizeMessagingAndUserHosts() {
        #expect(SleepExemptions.isExempt(host: "web.whatsapp.com", userHosts: []))
        #expect(SleepExemptions.isExempt(host: "www.example.com", userHosts: ["example.com"]))
        #expect(!SleepExemptions.isExempt(host: "example.org", userHosts: ["example.com"]))
    }
}
