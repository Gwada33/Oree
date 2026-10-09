import Testing
import Foundation
@testable import BrowserCore

/// Both tests below write the shared SettingsStore, so they must not run in parallel.
@Suite(.serialized) struct ThemePresetTests {
    @Test func applyThenMatches() {
        let store = SettingsStore.shared
        let saved = (store.appearanceMode, store.accentHue, store.density, store.cornerRadius, store.sidebarMode, store.homeBackground)
        defer {
            store.appearanceMode = saved.0; store.accentHue = saved.1; store.density = saved.2
            store.cornerRadius = saved.3; store.sidebarMode = saved.4; store.homeBackground = saved.5
        }
        for preset in ThemePreset.all {
            preset.apply(to: store)
            #expect(preset.matches(store), "\(preset.name)")
        }
        ThemePreset.all[0].apply(to: store)
        #expect(!ThemePreset.all[1].matches(store))
    }

    @Test func radiiStayInRange() {
        #expect(ThemePreset.all.allSatisfy { (0...16).contains($0.radius) })
        #expect(Set(ThemePreset.all.map(\.name)).count == ThemePreset.all.count)
    }

    @MainActor @Test func applyThenCaptureMatches() {
        let store = SettingsStore.shared
        let saved = LookProfile.capture(named: "tmp", from: store)
        defer { saved.apply(to: store) }
        for profile in LookProfile.builtIn {
            profile.apply(to: store)
            #expect(LookProfile.capture(named: profile.name, from: store) == profile)
        }
    }

}
