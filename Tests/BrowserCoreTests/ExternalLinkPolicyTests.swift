import Testing
import Foundation
@testable import BrowserCore

@Suite struct ExternalLinkPolicyTests {
    private func decide(_ s: String, click: Bool = true) -> ExternalLinkPolicy.Decision { ExternalLinkPolicy.decision(for: URL(string: s), userInitiated: click) }

    @Test func webPagesAreNotExternal() {
        #expect(decide("https://example.com") == .notExternal)
        #expect(decide("about:blank") == .notExternal)
        #expect(decide("oree://home") == .notExternal)
        #expect(decide("webkit-extension://abc/options.html") == .notExternal)
        #expect(decide("safari-web-extension://abc/options.html") == .notExternal)
        #expect(decide("data:text/html,hi") == .notExternal)
        #expect(ExternalLinkPolicy.decision(for: nil, userInitiated: true) == .notExternal)
    }

    @Test func mailAndPhoneOpenAtOnceWhenClicked() {
        #expect(decide("mailto:a@example.com") == .openDirectly)
        #expect(decide("tel:+33123456789") == .openDirectly)
        #expect(decide("sms:0612345678") == .openDirectly)
        #expect(decide("FaceTime://x") == .openDirectly)
    }

    @Test func otherAppSchemesAskFirst() {
        #expect(decide("zoommtg://zoom.us/join?confno=1") == .askFirst)
        #expect(decide("slack://open") == .askFirst)
        #expect(decide("spotify:track:1") == .askFirst)
    }

    @Test func dangerousSchemesNeverOpen() {
        for scheme in ["file:///etc/passwd", "ssh://host", "vnc://host", "smb://host/share", "x-apple.systempreferences:com.apple.preference.security", "applescript://x"] {
            #expect(decide(scheme) == .block, "\(scheme)")
        }
    }

    @Test func aScriptRedirectNeverLaunchesAnApp() {
        #expect(decide("mailto:a@example.com", click: false) == .block)
        #expect(decide("zoommtg://x", click: false) == .block)
        #expect(decide("https://example.com", click: false) == .notExternal)
    }
}
