import Testing
@testable import BrowserCore

@Suite("Mode responsive")
struct ResponsiveDeviceTests {
    @Test("un téléphone pivote en paysage, un ordinateur reste en paysage")
    func rotation() {
        let phone = ResponsiveDevice.presets[1]
        #expect(phone.size == (393, 852) && phone.rotated.size == (852, 393) && phone.rotated.rotated.size == (393, 852))
        let laptop = ResponsiveDevice.presets.first { $0.kind == .computer }!
        #expect(laptop.size == (1280, 800) && laptop.rotated.size == (1280, 800))
    }

    @Test("l'appareil ne dépasse jamais la place disponible, et dit s'il est réduit")
    func fit() {
        let phone = ResponsiveDevice.presets[1]
        let roomy = phone.fit(in: (1200, 900))
        #expect(roomy.width == 393 && roomy.height == 852 && !roomy.shrunk)
        let tight = phone.fit(in: (1200, 600))
        #expect(tight.width == 393 && tight.height == 568 && tight.shrunk)            // 600 − 2 × 16
        let tiny = ResponsiveDevice.presets.last!.fit(in: (500, 400))
        #expect(tiny.width == 468 && tiny.height == 368 && tiny.shrunk)
        #expect(phone.fit(in: (50, 50)).width == 200)                                  // jamais un sliver
    }

    @Test("l'identité annoncée suit la sorte d'appareil")
    func agents() {
        #expect(ResponsiveDevice.presets[0].userAgent?.contains("iPhone") == true)
        #expect(ResponsiveDevice.presets[3].userAgent?.contains("iPad") == true)
        #expect(ResponsiveDevice.presets[5].userAgent == nil)
        #expect(Set(ResponsiveDevice.presets.map(\.id)).count == ResponsiveDevice.presets.count)
        #expect(ResponsiveDevice.presets[1].label == "iPhone 15 · 393 × 852" && ResponsiveDevice.presets[1].rotated.label == "iPhone 15 · 852 × 393")
    }
}
