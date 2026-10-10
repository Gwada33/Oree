import Foundation
import IOKit.pwr_mgt

/// Keeps the screen from sleeping while the user cooks (kitchen mode). Released when the mode ends, the panel closes, or this is freed.
@MainActor
final class ScreenWake {
    private var assertion: IOPMAssertionID = 0
    private(set) var isHeld = false

    func hold(reason: String) {
        guard !isHeld else { return }
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &assertion)
        isHeld = result == kIOReturnSuccess
    }

    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(assertion)
        isHeld = false
    }

    deinit { if isHeld { IOPMAssertionRelease(assertion) } }
}
