import Testing
@testable import BrowserCore

@Suite struct DesignTokensTests {
    @Test func hexParsing() {
        let c = RGBA(hex: 0x2F7354)
        #expect(abs(c.r - 47.0 / 255) < 1e-9)
    }

    @Test func contrastReferenceValues() {
        let black = RGBA(hex: 0x000000), white = RGBA(hex: 0xFFFFFF)
        #expect(abs(black.contrast(with: white) - 21) < 0.01)
    }

    /// Body and secondary text must reach WCAG AA (4.5:1) on every surface they sit on, in both modes.
    @Test(arguments: [true, false])
    func textContrast(dark: Bool) {
        let T = OreeTokens.self
        for surface in [T.chrome, T.page, T.raised, T.field] {
            let bg = surface.resolved(dark: dark)
            #expect(T.text.resolved(dark: dark).contrast(with: bg) >= 4.5)
            #expect(T.muted.resolved(dark: dark).contrast(with: bg) >= 4.5)
        }
    }

    /// Hue ink on its own 12 % tint over page/chrome, and the label colour on a solid hue.
    @Test(arguments: [true, false], OreeTokens.Hue.allCases)
    func hueContrast(dark: Bool, hue: OreeTokens.Hue) {
        let T = OreeTokens.self
        for base in [T.page, T.chrome, T.raised] {
            let bg = base.resolved(dark: dark)
            let tint = hue.soft().resolved(dark: dark).over(bg)
            #expect(hue.ink.resolved(dark: dark).contrast(with: tint) >= 4.5, "\(hue) ink on tint")
            #expect(hue.ink.resolved(dark: dark).contrast(with: bg) >= 4.5, "\(hue) ink on surface")
            // The solid hue is used for shapes (lisière, ring): WCAG non-text minimum is 3:1.
            #expect(hue.solid.resolved(dark: dark).contrast(with: bg) >= 3, "\(hue) shape on surface")
        }
        let solid = hue.solid.resolved(dark: dark)
        #expect(hue.onSolid.resolved(dark: dark).contrast(with: solid) >= 4.5, "\(hue) label on solid")
    }

    @Test func radiiAreClamped() {
        #expect(OreeTokens.radii(base: 40).base == 16)
        #expect(OreeTokens.radii(base: -3).sm == 0)
    }

    @Test func densityRows() {
        #expect(OreeTokens.Density.aeree.rowHeight == 34)
        #expect(OreeTokens.Density.compacte.rowHeight == 25)
    }
}

@Suite struct SidebarModeTests {
    @Test func narrowWindowForcesCompact() {
        #expect(effectiveSidebarMode(.fixed, windowWidth: 880) == .compact)
        #expect(effectiveSidebarMode(.fixed, windowWidth: 1280) == .fixed)
        #expect(effectiveSidebarMode(.hidden, windowWidth: 700) == .hidden)
    }
}
