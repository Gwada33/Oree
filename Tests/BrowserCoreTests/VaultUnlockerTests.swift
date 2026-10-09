import Testing
import Foundation
@testable import BrowserCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

struct VaultUnlockerTests {
    @Test func successUnlocksForTheSessionWindow() async {
        let calls = Counter()
        let unlocker = VaultUnlocker(sessionDuration: 300, evaluate: { _ in calls.increment(); return true })
        #expect(await unlocker.authenticate(reason: "a"))
        #expect(await unlocker.authenticate(reason: "b"))
        #expect(calls.value == 1, "second call is inside the unlocked window")
    }

    @Test func failureDoesNotUnlock() async {
        let calls = Counter()
        let unlocker = VaultUnlocker(evaluate: { _ in calls.increment(); return false })
        #expect(await unlocker.authenticate(reason: "a") == false)
        #expect(await unlocker.authenticate(reason: "a") == false)
        #expect(calls.value == 2)
    }

    @Test func lockForcesANewPrompt() async {
        let calls = Counter()
        let unlocker = VaultUnlocker(evaluate: { _ in calls.increment(); return true })
        _ = await unlocker.authenticate(reason: "a")
        await unlocker.lock()
        _ = await unlocker.authenticate(reason: "a")
        #expect(calls.value == 2)
    }

    @Test func windowExpires() async {
        let calls = Counter()
        let clock = Counter()   // seconds
        let unlocker = VaultUnlocker(
            sessionDuration: 60,
            now: { Date(timeIntervalSince1970: Double(clock.value)) },
            evaluate: { _ in calls.increment(); return true }
        )
        _ = await unlocker.authenticate(reason: "a")
        for _ in 0..<61 { clock.increment() }
        _ = await unlocker.authenticate(reason: "a")
        #expect(calls.value == 2)
    }
}
