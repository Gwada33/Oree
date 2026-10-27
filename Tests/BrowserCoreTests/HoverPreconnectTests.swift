import Testing
import Foundation
@testable import BrowserCore

@Suite struct HoverPreconnectTests {
    @Test func delaysFollowLinkKind() {
        #expect(HoverPreconnect.delay(kind: "nav") == 200)
        #expect(HoverPreconnect.delay(kind: "button") == 250)
        #expect(HoverPreconnect.delay(kind: "content") == 350)
        #expect(HoverPreconnect.delay(kind: "inconnu") == 350)
    }
    @Test func onlyPublicWebAndNotPrivate() {
        let u = URL(string: "https://exemple.fr/a")!
        #expect(HoverPreconnect.allows(u, isPrivate: false, lowPower: false))
        #expect(!HoverPreconnect.allows(u, isPrivate: true, lowPower: false))
        #expect(!HoverPreconnect.allows(u, isPrivate: false, lowPower: true))
        #expect(!HoverPreconnect.allows(URL(string: "javascript:alert(1)")!, isPrivate: false, lowPower: false))
        #expect(!HoverPreconnect.allows(URL(string: "oree://home/")!, isPrivate: false, lowPower: false))
    }
    @Test func oncePerHostInWindow() {
        let r = HoverPreconnect.Recent(); let t = Date()
        #expect(r.shouldConnect(host: "a.fr", now: t))
        #expect(!r.shouldConnect(host: "a.fr", now: t.addingTimeInterval(5)))
        #expect(r.shouldConnect(host: "b.fr", now: t.addingTimeInterval(5)))
        #expect(r.shouldConnect(host: "a.fr", now: t.addingTimeInterval(25)))
    }
}
