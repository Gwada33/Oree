import Testing
@testable import BrowserCore

@Suite struct ShortcutsTests {
    @Test func defaultsHaveNoConflicts() {
        let resolved = ShortcutRegistry.resolve(overrides: [:])
        let bindings = Array(resolved.values)
        #expect(Set(bindings).count == bindings.count, "two commands share a default shortcut")
        #expect(bindings.allSatisfy { $0.isUsable })
        #expect(bindings.allSatisfy { !ShortcutRegistry.isReserved($0) })
    }

    @Test func idsAreUnique() {
        #expect(Set(ShortcutRegistry.commands.map(\.id)).count == ShortcutRegistry.commands.count)
    }

    @Test func overridesReplaceAndClear() {
        let custom = KeyBinding("j", [.command, .option])
        var resolved = ShortcutRegistry.resolve(overrides: ["newTab": custom, "closeTab": KeyBinding("", [])])
        #expect(resolved["newTab"] == custom)
        #expect(resolved["closeTab"] == nil)
        #expect(resolved["palette"] == KeyBinding("k", [.command]))
        resolved = ShortcutRegistry.resolve(overrides: [:])
        #expect(ShortcutRegistry.conflict(for: KeyBinding("k", [.command]), excluding: "newTab", in: resolved)?.id == "palette")
        #expect(ShortcutRegistry.conflict(for: KeyBinding("k", [.command]), excluding: "palette", in: resolved) == nil)
    }

    @Test func displayText() {
        #expect(KeyBinding("l", [.command, .shift]).display == "⇧⌘L")
        #expect(KeyBinding("s", [.command, .option]).display == "⌥⌘S")
        #expect(KeyBinding(KeyBinding.upArrow, [.control]).display == "⌃↑")
    }

    @Test func shiftAloneIsNotUsable() {
        #expect(!KeyBinding("a", [.shift]).isUsable)
        #expect(!KeyBinding("a", []).isUsable)
        #expect(KeyBinding("a", [.control]).isUsable)
    }
}
