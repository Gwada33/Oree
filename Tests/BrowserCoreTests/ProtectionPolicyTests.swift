import Testing
@testable import BrowserCore

@Suite struct ProtectionPolicyTests {
    @Test func matchesTheHostAndItsSubdomains() {
        let list = ["youtube.com", "mail.google.com"]
        #expect(ProtectionPolicy.isExempt(host: "www.youtube.com", list: list))
        #expect(ProtectionPolicy.isExempt(host: "m.youtube.com", list: list))
        #expect(ProtectionPolicy.isExempt(host: "mail.google.com", list: list))
        #expect(!ProtectionPolicy.isExempt(host: "google.com", list: list))
        #expect(!ProtectionPolicy.isExempt(host: "notyoutube.com", list: list))
        #expect(!ProtectionPolicy.isExempt(host: nil, list: list))
    }
}
