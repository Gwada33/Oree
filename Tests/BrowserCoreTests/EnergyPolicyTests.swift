import Testing
import Foundation
@testable import BrowserCore

@Suite struct EnergyPolicyTests {
    @Test func theModeDecidesWhenItIsOn() {
        #expect(EnergyPolicy.isActive(mode: .automatic, systemLowPower: true))
        #expect(!EnergyPolicy.isActive(mode: .automatic, systemLowPower: false))
        #expect(EnergyPolicy.isActive(mode: .always, systemLowPower: false))
        #expect(!EnergyPolicy.isActive(mode: .never, systemLowPower: true))
    }

    @Test func patienceIsHalvedButNeverBelowTheFloors() {
        let normal = TabLifecyclePolicy.Timing(freezeAfter: 120, sleepAfter: 2700)
        let saving = EnergyPolicy.adjusted(normal, active: true)
        #expect(saving.freezeAfter == 60 && saving.sleepAfter == 1350)
        let already = EnergyPolicy.adjusted(.init(freezeAfter: 40, sleepAfter: 100), active: true)
        #expect(already.freezeAfter == 30 && already.sleepAfter == 100)      // the floor, but never longer than before
        #expect(EnergyPolicy.adjusted(normal, active: false) == normal)
    }

    @Test func disabledStepsStayDisabled() {
        let result = EnergyPolicy.adjusted(.init(freezeAfter: 0, sleepAfter: 0), active: true)
        #expect(result.freezeAfter == 0 && result.sleepAfter == 0)
    }
}
